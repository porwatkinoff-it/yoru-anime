// Аккаунт Yoru: свой сервер yoru-sync (Proxmox). Формат и шифрование — как на Android и iPhone.
// Пароль на сервер не уходит: из него выводятся ключ входа и ключ шифрования.
// Входы в Anime 365, MangaLib, Com-X и Шикимори шифруются ключом от пароля, сервер хранит только шифротекст.
// История и прогресс лежат в localStorage интерфейса: страница отдаёт их сюда, а получает слитое состояние.
use crate::{manga::Manga, write_private, Yoru, UA};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use ring::{aead, hmac, pbkdf2, rand::{SecureRandom, SystemRandom}};
use serde_json::{json, Map, Value};
use std::{
    collections::HashSet,
    fs,
    net::{Ipv4Addr, UdpSocket},
    num::NonZeroU32,
    path::PathBuf,
    sync::{atomic::{AtomicBool, Ordering}, Mutex, OnceLock},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use tauri::{AppHandle, Emitter, Manager, State};

pub const DEFAULT_SERVER: &str = "https://yoru.tailfdcf3d.ts.net";
const SERVICES: [&str; 4] = ["anime365", "mangalib", "comx", "shikimori"];
const ROUNDS: u32 = 210_000;
#[cfg(target_os = "macos")]
const DEVICE: &str = "Mac";
#[cfg(windows)]
const DEVICE: &str = "Windows";
#[cfg(not(any(target_os = "macos", windows)))]
const DEVICE: &str = "Linux";

static APP: OnceLock<AppHandle> = OnceLock::new();

pub struct Account {
    st: Mutex<Value>,
    file: PathBuf,
    http: reqwest::Client,
    lock: tokio::sync::Mutex<()>,
    installing: AtomicBool,
    installed: Mutex<HashSet<String>>,
    qr: Mutex<Option<LoginCode>>,
}

#[derive(Clone)]
struct LoginCode {
    id: String,
    poll: String,
    key: [u8; 32],
    server: String,
}

impl LoginCode {
    fn request(&self) -> Value { json!({ "id": self.id, "poll": self.poll }) }
}

fn now_ms() -> i64 { SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0) }
fn now_s() -> i64 { now_ms() / 1000 }
fn s(v: &Value) -> String { v.as_str().unwrap_or("").to_string() }

// ───────────── Шифрование ─────────────
// master = PBKDF2-HMAC-SHA256(пароль в NFC UTF-8, соль, 210000, 32 байта); auth/enc = HMAC(master, "yoru-auth"/"yoru-enc").
// NFC делает страница (String.normalize), здесь пароль уже нормализован.
async fn keys(password: String, salt: Vec<u8>) -> ([u8; 32], [u8; 32]) {
    tauri::async_runtime::spawn_blocking(move || {
        let mut m = [0u8; 32];
        pbkdf2::derive(pbkdf2::PBKDF2_HMAC_SHA256, NonZeroU32::new(ROUNDS).unwrap(), &salt, password.as_bytes(), &mut m);
        let k = hmac::Key::new(hmac::HMAC_SHA256, &m);
        let mut a = [0u8; 32];
        let mut e = [0u8; 32];
        a.copy_from_slice(hmac::sign(&k, b"yoru-auth").as_ref());
        e.copy_from_slice(hmac::sign(&k, b"yoru-enc").as_ref());
        (a, e)
    }).await.unwrap()
}
fn random<const N: usize>() -> [u8; N] { let mut b = [0u8; N]; SystemRandom::new().fill(&mut b).expect("random"); b }
fn gcm(key: &[u8]) -> Option<aead::LessSafeKey> { aead::UnboundKey::new(&aead::AES_256_GCM, key).ok().map(aead::LessSafeKey::new) }
// AES-GCM: nonce(12) + шифротекст + тег(16) в base64 — тот же вид, что CryptoKit combined на iPhone.
fn seal(data: &[u8], key: &[u8]) -> Option<String> {
    let n: [u8; 12] = random();
    let mut buf = data.to_vec();
    gcm(key)?.seal_in_place_append_tag(aead::Nonce::assume_unique_for_key(n), aead::Aad::empty(), &mut buf).ok()?;
    let mut out = n.to_vec();
    out.extend(buf);
    Some(B64.encode(out))
}
fn open(text: &str, key: &[u8]) -> Option<Vec<u8>> {
    let d = B64.decode(text).ok()?;
    if d.len() < 28 { return None; }
    let n = aead::Nonce::try_assume_unique_for_key(&d[..12]).ok()?;
    let mut buf = d[12..].to_vec();
    let plain = gcm(key)?.open_in_place(n, aead::Aad::empty(), &mut buf).ok()?;
    Some(plain.to_vec())
}

// ───────────── Хранение ─────────────
// yoru-account.json (только для этого пользователя): server, lan, viaLan, login, token, enc, vt {сервис: мс}, vdel {сервис: true}, synced.
impl Account {
    pub fn new(dir: &std::path::Path) -> Self {
        let file = dir.join("yoru-account.json");
        let st = fs::read(&file).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok()).filter(Value::is_object).unwrap_or_else(|| json!({}));
        let http = reqwest::Client::builder().user_agent(UA).connect_timeout(Duration::from_secs(12)).build().expect("http");
        Account { st: Mutex::new(st), file, http, lock: tokio::sync::Mutex::new(()), installing: AtomicBool::new(false), installed: Mutex::new(HashSet::new()), qr: Mutex::new(None) }
    }
    fn get(&self, k: &str) -> String { s(&self.st.lock().unwrap()[k]) }
    fn edit(&self, f: impl FnOnce(&mut Map<String, Value>)) {
        let mut st = self.st.lock().unwrap();
        if !st.is_object() { *st = json!({}); }
        f(st.as_object_mut().unwrap());
        let _ = write_private(&self.file, st.to_string().as_bytes());
    }
    fn logged(&self) -> bool { !self.get("token").is_empty() }
    fn enc(&self) -> Option<Vec<u8>> { B64.decode(self.get("enc")).ok().filter(|k| k.len() == 32) }
    fn vt(&self, svc: &str) -> i64 { self.st.lock().unwrap()["vt"][svc].as_i64().unwrap_or(0) }
    fn main_base(&self) -> String {
        let t = self.get("server");
        let t = t.trim().trim_end_matches('/').trim();
        if t.is_empty() { DEFAULT_SERVER.into() } else if t.contains("://") { t.into() } else { format!("https://{t}") }
    }

    // ───────────── Запросы ─────────────
    // Сначала адрес, который ответил в прошлый раз; при сетевой ошибке — второй (домашняя сеть или интернет).
    // Домашний провайдер режет *.ts.net, поэтому дома запросы идут на сервер напрямую.
    async fn call(&self, path: &str, body: Value, auth: bool) -> Result<Value, String> {
        let main = self.main_base();
        let def = main == DEFAULT_SERVER;
        let mut bases = vec![main.clone()];
        let lan = self.get("lan");
        if def && !lan.is_empty() {
            if self.st.lock().unwrap()["viaLan"].as_bool() == Some(true) { bases.insert(0, lan); } else { bases.push(lan); }
        }
        let token = self.get("token");
        let mut looked = false;
        let mut i = 0;
        while i < bases.len() {
            let base = bases[i].clone();
            let mut req = self.http.post(format!("{base}{path}")).json(&body)
                .timeout(Duration::from_secs(if base == main { 25 } else { 8 }));
            if auth { req = req.bearer_auth(&token); }
            match req.send().await {
                Ok(res) => {
                    let code = res.status().as_u16();
                    if def { let via = base != main; self.edit(|m| { m.insert("viaLan".into(), via.into()); }); }
                    let j: Value = res.json().await.unwrap_or_else(|_| json!({}));
                    let err = j["error"].as_str().map(str::to_string);
                    if code == 401 && auth {
                        self.signed_out();
                        emit("signedOut");
                        return Err(err.unwrap_or_else(|| "Вход в аккаунт Yoru завершён. Войдите снова.".into()));
                    }
                    if code != 200 { return Err(err.unwrap_or_else(|| format!("Сервер Yoru ответил ошибкой ({code})"))); }
                    return Ok(j);
                }
                Err(_) => {
                    if i == bases.len() - 1 && def && !looked {
                        looked = true;
                        if let Some(found) = find_lan().await {
                            if !bases.contains(&found) { let f = found.clone(); self.edit(|m| { m.insert("lan".into(), f.into()); }); bases.push(found); }
                        }
                    }
                }
            }
            i += 1;
        }
        Err("Сервер Yoru недоступен. Проверьте интернет.".into())
    }
    async fn salt(&self, who: &str) -> Result<Vec<u8>, String> {
        let j = self.call("/v1/prelogin", json!({ "login": who }), false).await?;
        B64.decode(s(&j["salt"])).ok().filter(|b| !b.is_empty()).ok_or_else(|| "Сервер Yoru ответил неожиданно".into())
    }

    fn signed_in(&self, app: &AppHandle, j: &Value, enc: &[u8]) {
        let (token, login, enc) = (s(&j["token"]), s(&j["login"]), B64.encode(enc));
        // Только те, где здесь действительно есть вход: пустая отметка 1 заслонила бы вход из аккаунта.
        let have: Vec<&str> = SERVICES.iter().copied().filter(|svc| self.payload(app, svc).is_some()).collect();
        self.edit(|m| {
            m.insert("token".into(), token.into());
            m.insert("enc".into(), enc.into());
            m.insert("login".into(), login.into());
            // Входы этого устройства, сделанные до аккаунта, тоже уходят в аккаунт, но уступают более новым.
            let vt = m.entry("vt").or_insert_with(|| json!({}));
            if !vt.is_object() { *vt = json!({}); }
            for svc in &have { if vt[*svc].as_i64().unwrap_or(0) == 0 { vt[*svc] = 1.into(); } }
            m.insert("vfix".into(), 1.into());
        });
        self.installed.lock().unwrap().clear();
    }
    fn signed_out(&self) {
        // После выхода входы этого устройства снова «свои»: при следующем входе они уступят аккаунту.
        self.edit(|m| { for k in ["token", "enc", "login", "synced", "vt", "vdel"] { m.remove(k); } });
    }

    // ───────────── Входы в сервисы ─────────────
    // Единый формат для всех устройств: anime365 {"token"}; mangalib {"access","refresh","expires" (мс с 1970),"name"};
    // comx [{name,value,domain,path,secure,expires (секунды с 1970)}];
    // shikimori {"id","secret" (ключи приложения),"access","refresh","expires" (мс с 1970),"userId","nickname"}.
    fn payload(&self, app: &AppHandle, svc: &str) -> Option<Vec<u8>> {
        let v = match svc {
            "anime365" => {
                let t = app.state::<Yoru>().token.lock().unwrap().clone();
                if t.is_empty() { return None; }
                json!({ "token": t })
            }
            "mangalib" => {
                let l = app.state::<Manga>().lib.lock().unwrap().clone();
                let access = s(&l["access"]);
                if access.is_empty() { return None; }
                json!({ "access": access, "refresh": s(&l["refresh"]), "expires": l["expires"].as_i64().unwrap_or(0) * 1000, "name": s(&l["name"]) })
            }
            "comx" => {
                if !crate::manga::comx_logged(app) { return None; }
                let year = now_s() + 365 * 86400;
                let list: Vec<Value> = crate::manga::comx_cookies(app).iter()
                    .filter(|c| c.name().starts_with("dle_") || c.name() == "PHPSESSID")
                    .map(|c| json!({
                        "name": c.name(), "value": c.value(),
                        "domain": c.domain().filter(|d| !d.is_empty()).unwrap_or("com-x.life"),
                        "path": c.path().filter(|p| !p.is_empty()).unwrap_or("/"),
                        "secure": c.secure().unwrap_or(true),
                        "expires": c.expires_datetime().map(|t| t.unix_timestamp()).unwrap_or(year),
                    })).collect();
                if list.is_empty() { return None; }
                Value::Array(list)
            }
            "shikimori" => app.state::<crate::shiki::Shiki>().vault_payload()?,
            _ => return None,
        };
        Some(v.to_string().into_bytes())
    }
    fn export_vault(&self, app: &AppHandle) -> Value {
        let mut out = Map::new();
        let Some(enc) = self.enc() else { return Value::Object(out) };
        // До 2.3.1 вход в аккаунт ставил отметку 1 и сервисам без входа — тогда вход с другого устройства не приходил. Один раз чистим.
        if self.st.lock().unwrap()["vfix"].as_i64().is_none() {
            let st = self.st.lock().unwrap().clone();
            let empty: Vec<&str> = SERVICES.iter().copied()
                .filter(|svc| st["vt"][*svc].as_i64() == Some(1) && st["vdel"][*svc].as_bool() != Some(true) && self.payload(app, svc).is_none()).collect();
            self.edit(|m| {
                if let Some(vt) = m.get_mut("vt").and_then(Value::as_object_mut) { for svc in &empty { vt.remove(*svc); } }
                m.insert("vfix".into(), 1.into());
            });
        }
        // Вход в Шикимори, сделанный до того, как он стал частью аккаунта, тоже уходит в аккаунт (уступая более новым).
        if self.vt("shikimori") == 0 && self.payload(app, "shikimori").is_some() {
            self.edit(|m| { let vt = m.entry("vt").or_insert_with(|| json!({})); if !vt.is_object() { *vt = json!({}); } vt["shikimori"] = 1.into(); });
        }
        let st = self.st.lock().unwrap().clone();
        for svc in SERVICES {
            let t = st["vt"][svc].as_i64().unwrap_or(0);
            if t <= 0 { continue; }
            if st["vdel"][svc].as_bool() == Some(true) { out.insert(svc.into(), json!({ "t": t, "d": null })); continue; }
            if let Some(d) = self.payload(app, svc).and_then(|p| seal(&p, &enc)) { out.insert(svc.into(), json!({ "t": t, "d": d })); }
        }
        Value::Object(out)
    }
    async fn install_vault(&self, app: &AppHandle, st: &Value) -> Vec<String> {
        let mut done = Vec::new();
        let (Some(vault), Some(enc)) = (st["vault"].as_object(), self.enc()) else { return done };
        for svc in SERVICES {
            let Some(e) = vault.get(svc) else { continue };
            let t = e["t"].as_i64().unwrap_or(0);
            if t <= self.vt(svc) { continue; }
            let plain = match &e["d"] {
                // Не расшифровалось — запись сделана другим паролем; не трогаем.
                Value::String(d) => match open(d, &enc) { Some(p) => Some(p), None => continue },
                _ => None,
            };
            self.installing.store(true, Ordering::SeqCst);
            let ok = install(app, svc, plain).await;
            self.installing.store(false, Ordering::SeqCst);
            if !ok { continue; }
            self.edit(|m| {
                let vt = m.entry("vt").or_insert_with(|| json!({}));
                vt[svc] = t.into();
                if let Some(d) = m.get_mut("vdel").and_then(Value::as_object_mut) { d.remove(svc); }
            });
            self.installed.lock().unwrap().insert(svc.to_string());
            done.push(svc.to_string());
        }
        done
    }

    // Слияние на сервере; ответ — общее состояние. Входы в сервисы ставятся здесь, остальное сливает страница.
    async fn sync(&self, app: &AppHandle, state: Value) -> Result<Value, String> {
        let _g = self.lock.lock().await;
        if !self.logged() { return Err("Войдите в аккаунт Yoru".into()); }
        let mut state = if state.is_object() { state } else { json!({ "v": 1 }) };
        state["vault"] = self.export_vault(app);
        let j = self.call("/v1/sync", json!({ "state": state }), true).await?;
        let mut out = j["state"].clone();
        if !out.is_object() { return Ok(json!({ "state": null, "installed": [] })); }
        let installed = self.install_vault(app, &out).await;
        out.as_object_mut().unwrap().remove("vault");
        let t = now_ms();
        self.edit(|m| { m.insert("synced".into(), t.into()); });
        Ok(json!({ "state": out, "installed": installed }))
    }
}

fn emit(kind: &str) { if let Some(a) = APP.get() { let _ = a.emit("yoruChanged", kind); } }
fn account() -> Option<&'static Account> { APP.get().map(|a| a.state::<Account>().inner()) }

pub fn init(app: &AppHandle) { let _ = APP.set(app.clone()); }

// Вход в сервис изменился на этом устройстве: отметка времени и синхронизация через пару секунд (её запускает страница).
pub fn vault_changed(svc: &str) {
    let Some(a) = account() else { return };
    if a.installing.load(Ordering::SeqCst) || !a.logged() { return; }
    let t = now_ms();
    a.edit(|m| {
        let vt = m.entry("vt").or_insert_with(|| json!({}));
        if !vt.is_object() { *vt = json!({}); }
        vt[svc] = t.into();
        if let Some(d) = m.get_mut("vdel").and_then(Value::as_object_mut) { d.remove(svc); }
    });
    emit("dirty");
}

// Вход в сервис перестал работать: возможно, другое устройство уже обновило его в аккаунте.
pub async fn recover(svc: &str) -> bool {
    let (Some(app), Some(a)) = (APP.get(), account()) else { return false };
    if !a.logged() { return false; }
    a.installed.lock().unwrap().remove(svc);
    if a.sync(app, json!({ "v": 1 })).await.is_err() { return false; }
    a.installed.lock().unwrap().contains(svc)
}

async fn install(app: &AppHandle, svc: &str, plain: Option<Vec<u8>>) -> bool {
    let v: Option<Value> = match plain {
        Some(p) => match serde_json::from_slice(&p) { Ok(v) => Some(v), Err(_) => return false },
        None => None,
    };
    match svc {
        "anime365" => {
            let t = v.as_ref().map(|v| s(&v["token"])).unwrap_or_default();
            let y = app.state::<Yoru>();
            y.save_token(&t);
            *y.token.lock().unwrap() = t;
        }
        "mangalib" => {
            let m = app.state::<Manga>();
            match v {
                None => m.store(Value::Null),
                Some(o) => {
                    if s(&o["access"]).is_empty() { return true; }
                    let exp = o["expires"].as_f64().unwrap_or(0.0) as i64 / 1000;
                    m.store(json!({ "access": s(&o["access"]), "refresh": s(&o["refresh"]), "expires": exp, "name": s(&o["name"]) }));
                }
            }
        }
        "comx" => {
            use tauri::webview::cookie::{time::OffsetDateTime, Cookie};
            let Some(w) = app.get_webview_window("comx").or_else(|| app.get_webview_window("main")) else { return false };
            for c in crate::manga::comx_cookies(app) {
                if c.name().starts_with("dle_") || c.name() == "PHPSESSID" { let _ = w.delete_cookie(c); }
            }
            if let Some(list) = v.as_ref().and_then(Value::as_array) {
                let now = now_s();
                for k in list {
                    let name = s(&k["name"]);
                    if name.is_empty() { continue; }
                    let domain = Some(s(&k["domain"])).filter(|d| !d.is_empty()).unwrap_or_else(|| "com-x.life".into());
                    let path = Some(s(&k["path"])).filter(|p| !p.is_empty()).unwrap_or_else(|| "/".into());
                    let mut b = Cookie::build((name, s(&k["value"]))).domain(domain).path(path).secure(k["secure"].as_bool().unwrap_or(true));
                    let exp = k["expires"].as_f64().unwrap_or(0.0) as i64;
                    if exp > now { if let Ok(t) = OffsetDateTime::from_unix_timestamp(exp) { b = b.expires(t); } }
                    let _ = w.set_cookie(b.build());
                }
            }
            *app.state::<Manga>().comx_ready.lock().await = false;
        }
        "shikimori" => app.state::<crate::shiki::Shiki>().install(v.as_ref()),
        _ => return false,
    }
    emit(&format!("installed:{svc}"));
    true
}

// ───────────── Поиск сервера в домашней сети ─────────────
// Домашний yoru-sync объявляет себя как _yoru-sync._tcp (avahi). Запрос mDNS «legacy unicast»:
// с обычного порта на 224.0.0.251:5353, ответ приходит прямо на этот порт. Берём IPv4 и порт из SRV и A.
const SERVICE: &str = "_yoru-sync._tcp.local";
fn query(name: &str, qtype: u16) -> Vec<u8> {
    let mut q = vec![0x59, 0x52, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0];
    for l in name.trim_end_matches('.').split('.') { q.push(l.len() as u8); q.extend(l.as_bytes()); }
    q.push(0);
    q.extend(qtype.to_be_bytes());
    q.extend(1u16.to_be_bytes());
    q
}
fn read_name(b: &[u8], mut i: usize) -> Option<(String, usize)> {
    let (mut out, mut end, mut hops) = (Vec::new(), None, 0);
    loop {
        let l = *b.get(i)? as usize;
        if l == 0 { i += 1; break; }
        if l & 0xC0 == 0xC0 {
            if end.is_none() { end = Some(i + 2); }
            i = ((l & 0x3F) << 8) | *b.get(i + 1)? as usize;
            hops += 1;
            if hops > 30 { return None; }
            continue;
        }
        out.push(String::from_utf8_lossy(b.get(i + 1..i + 1 + l)?).to_string());
        i += 1 + l;
    }
    Some((out.join(".").to_lowercase(), end.unwrap_or(i)))
}
// Записи ответа: (имя, тип, начало данных, длина данных).
fn records(b: &[u8]) -> Option<Vec<(String, u16, usize, usize)>> {
    let u16at = |i: usize| -> Option<u16> { Some(u16::from_be_bytes([*b.get(i)?, *b.get(i + 1)?])) };
    let qd = u16at(4)? as usize;
    let rr = u16at(6)? as usize + u16at(8)? as usize + u16at(10)? as usize;
    let mut i = 12;
    for _ in 0..qd { i = read_name(b, i)?.1 + 4; }
    let mut out = Vec::new();
    for _ in 0..rr {
        let (name, j) = read_name(b, i)?;
        let t = u16at(j)?;
        let len = u16at(j + 8)? as usize;
        if j + 10 + len > b.len() { return None; }
        out.push((name, t, j + 10, len));
        i = j + 10 + len;
    }
    Some(out)
}
async fn find_lan() -> Option<String> {
    tauri::async_runtime::spawn_blocking(|| {
        let sock = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)).ok()?;
        sock.set_read_timeout(Some(Duration::from_millis(400))).ok()?;
        let dst = (Ipv4Addr::new(224, 0, 0, 251), 5353);
        let start = Instant::now();
        let (mut srv, mut addrs): (Option<(u16, String)>, Vec<(String, Ipv4Addr)>) = (None, Vec::new());
        let mut last = Instant::now() - Duration::from_secs(5);
        let mut buf = [0u8; 9000];
        while start.elapsed() < Duration::from_secs(3) {
            if last.elapsed() >= Duration::from_secs(1) {
                last = Instant::now();
                let _ = sock.send_to(&query(SERVICE, 12), dst);
                if let Some((_, target)) = &srv { let _ = sock.send_to(&query(target, 1), dst); }
            }
            let Ok((n, _)) = sock.recv_from(&mut buf) else { continue };
            let b = &buf[..n];
            for (name, t, at, len) in records(b).unwrap_or_default() {
                if t == 33 && len >= 7 && name.ends_with(SERVICE) && srv.is_none() {
                    let port = u16::from_be_bytes([b[at + 4], b[at + 5]]);
                    if let Some((target, _)) = read_name(b, at + 6) { srv = Some((port, target)); last = Instant::now() - Duration::from_secs(5); }
                } else if t == 1 && len == 4 {
                    addrs.push((name, Ipv4Addr::new(b[at], b[at + 1], b[at + 2], b[at + 3])));
                }
            }
            if let Some((port, target)) = &srv {
                if let Some((_, ip)) = addrs.iter().find(|(n, _)| n == target) { return Some(format!("http://{ip}:{port}")); }
            }
        }
        None
    }).await.ok().flatten()
}

// ───────────── Команды для страницы ─────────────
type R = Result<Value, String>;
fn need(a: &Account) -> Result<(), String> { if a.logged() { Ok(()) } else { Err("Войдите в аккаунт Yoru".into()) } }

#[tauri::command]
pub fn account_status(a: State<'_, Account>) -> Value {
    let st = a.st.lock().unwrap().clone();
    json!({ "signedIn": !s(&st["token"]).is_empty(), "login": s(&st["login"]), "server": s(&st["server"]), "defaultServer": DEFAULT_SERVER,
            "synced": st["synced"].as_i64().unwrap_or(0), "viaLan": st["viaLan"].as_bool().unwrap_or(false) })
}

#[tauri::command]
pub fn account_set_server(a: State<'_, Account>, server: String) -> bool {
    let mut qr = a.qr.lock().unwrap();
    *qr = None;
    let v = server.trim().to_string();
    a.edit(|m| { m.insert("server".into(), v.into()); });
    true
}

#[tauri::command]
pub async fn account_register(app: AppHandle, a: State<'_, Account>, login: String, email: String, invite: String, password: String) -> R {
    let salt: [u8; 16] = random();
    let (auth, enc) = keys(password, salt.to_vec()).await;
    let j = a.call("/v1/register", json!({ "login": login.trim(), "email": email.trim(), "invite": invite.trim(), "salt": B64.encode(salt), "auth": B64.encode(auth), "device": DEVICE }), false).await?;
    a.signed_in(&app, &j, &enc);
    Ok(json!({ "login": j["login"], "mailed": j["mailed"] }))
}

#[tauri::command]
pub async fn account_sign_in(app: AppHandle, a: State<'_, Account>, login: String, password: String) -> R {
    let who = login.trim().to_string();
    let (auth, enc) = keys(password, a.salt(&who).await?).await;
    let j = a.call("/v1/login", json!({ "login": who, "auth": B64.encode(auth), "device": DEVICE }), false).await?;
    a.signed_in(&app, &j, &enc);
    Ok(json!({ "login": j["login"] }))
}

#[tauri::command]
pub async fn account_qr_start(a: State<'_, Account>) -> R {
    if a.logged() { return Err("Устройство уже подключено к аккаунту Yoru".into()); }
    let server = a.main_base();
    let reply = a.call("/v1/qr/start", json!({ "device": DEVICE }), false).await?;
    let id = s(&reply["id"]);
    let poll = s(&reply["poll"]);
    let expires = reply["expiresIn"].as_u64().filter(|n| (1..=180).contains(n));
    if id.len() != 32 || !id.bytes().all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase()) ||
        poll.len() != 43 || !poll.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_') {
        return Err("Сервер Yoru не вернул QR-код".into());
    }
    let expires = expires.ok_or("Сервер Yoru не вернул срок действия QR-кода")?;
    let key = random::<32>();
    let qr = qrcode::QrCode::new(format!("yoru-pair:v1:{id}:{}", B64.encode(key)))
        .map_err(|_| "Не удалось создать QR-код")?;
    let modules: Vec<bool> = qr.to_colors().into_iter().map(|c| c == qrcode::types::Color::Dark).collect();
    let mut pending = a.qr.lock().unwrap();
    if a.logged() || a.main_base() != server { return Err("Откройте вход по QR-коду заново".into()); }
    *pending = Some(LoginCode { id: id.clone(), poll, key, server });
    Ok(json!({ "id": id, "shortCode": id[..6].to_ascii_uppercase(), "expiresIn": expires,
               "width": qr.width(), "modules": modules }))
}

#[tauri::command]
pub async fn account_qr_poll(app: AppHandle, a: State<'_, Account>, id: String) -> R {
    let offer = a.qr.lock().unwrap().as_ref().filter(|q| q.id == id).cloned().ok_or("QR-код уже закрыт")?;
    if a.logged() || a.main_base() != offer.server { return Err("Откройте вход по QR-коду заново".into()); }
    let reply = a.call("/v1/qr/poll", offer.request(), false).await?;
    if reply["status"].as_str() == Some("pending") { return Ok(json!({ "signedIn": false })); }
    if reply["status"].as_str() != Some("approved") || s(&reply["token"]).is_empty() || s(&reply["login"]).is_empty() {
        return Err("Сервер Yoru ответил неожиданно".into());
    }
    let enc = open(&s(&reply["sealedKey"]), &offer.key).filter(|key| key.len() == 32)
        .ok_or("Не удалось прочитать ключ аккаунта. Откройте новый QR-код.")?;
    let mut pending = a.qr.lock().unwrap();
    if pending.as_ref().map(|q| q.id.as_str()) != Some(id.as_str()) || a.logged() || a.main_base() != offer.server {
        return Err("QR-код уже закрыт".into());
    }
    *pending = None;
    a.signed_in(&app, &reply, &enc);
    Ok(json!({ "signedIn": true }))
}

#[tauri::command]
pub async fn account_qr_cancel(a: State<'_, Account>, id: String) -> Result<(), String> {
    let offer = {
        let mut pending = a.qr.lock().unwrap();
        if pending.as_ref().map(|q| q.id.as_str()) != Some(id.as_str()) { return Ok(()); }
        pending.take().unwrap()
    };
    if offer.server == a.main_base() { let _ = a.call("/v1/qr/cancel", offer.request(), false).await; }
    Ok(())
}

#[tauri::command]
pub async fn account_forgot(a: State<'_, Account>, login: String) -> R {
    let j = a.call("/v1/forgot", json!({ "login": login.trim() }), false).await?;
    Ok(j.get("note").cloned().unwrap_or_else(|| "Если у аккаунта подтверждена почта, на неё отправлен код.".into()))
}

// Новый пароль по коду из письма. Входы в сервисы были зашифрованы старым паролем — их придётся повторить.
#[tauri::command]
pub async fn account_reset(app: AppHandle, a: State<'_, Account>, login: String, code: String, password: String) -> R {
    let salt: [u8; 16] = random();
    let (auth, enc) = keys(password, salt.to_vec()).await;
    let j = a.call("/v1/reset", json!({ "login": login.trim(), "code": code.trim(), "salt": B64.encode(salt), "auth": B64.encode(auth), "device": DEVICE }), false).await?;
    a.signed_in(&app, &j, &enc);
    Ok(json!({ "login": j["login"] }))
}

#[tauri::command]
pub async fn account_me(a: State<'_, Account>) -> R {
    need(&a)?;
    let j = a.call("/v1/me", json!({}), true).await?;
    let l = s(&j["login"]);
    if !l.is_empty() && l != a.get("login") { a.edit(|m| { m.insert("login".into(), l.into()); }); }
    Ok(j)
}

#[tauri::command]
pub async fn account_verify_email(a: State<'_, Account>, code: String) -> R { need(&a)?; a.call("/v1/verify-email", json!({ "code": code.trim() }), true).await }

#[tauri::command]
pub async fn account_resend(a: State<'_, Account>) -> R { need(&a)?; a.call("/v1/resend", json!({}), true).await }

#[tauri::command]
pub async fn account_change_email(a: State<'_, Account>, email: String, password: String) -> R {
    need(&a)?;
    let (auth, _) = keys(password, a.salt(&a.get("login")).await?).await;
    a.call("/v1/email", json!({ "email": email.trim(), "old": B64.encode(auth) }), true).await
}

// Смена пароля: входы в сервисы перешифровываются новым ключом прямо на устройстве.
#[tauri::command]
pub async fn account_change_password(app: AppHandle, a: State<'_, Account>, old: String, fresh: String) -> R {
    need(&a)?;
    let (old_auth, old_enc) = keys(old, a.salt(&a.get("login")).await?).await;
    let _g = a.lock.lock().await;
    let j = a.call("/v1/sync", json!({ "state": { "v": 1, "vault": a.export_vault(&app) } }), true).await?;
    let salt: [u8; 16] = random();
    let (auth, enc) = keys(fresh, salt.to_vec()).await;
    let mut out = Map::new();
    if let Some(vault) = j["state"]["vault"].as_object() {
        for (svc, e) in vault {
            let mut e = e.clone();
            if let Value::String(d) = &e["d"] {
                let Some(plain) = open(d, &old_enc) else { continue };
                let Some(sealed) = seal(&plain, &enc) else { continue };
                e["d"] = sealed.into();
            }
            out.insert(svc.clone(), e);
        }
    }
    a.call("/v1/password", json!({ "old": B64.encode(old_auth), "salt": B64.encode(salt), "auth": B64.encode(auth), "vault": out }), true).await?;
    let k = B64.encode(enc);
    a.edit(|m| { m.insert("enc".into(), k.into()); });
    Ok(json!(true))
}

#[tauri::command]
pub async fn account_sign_out(a: State<'_, Account>, all: bool) -> R {
    if a.logged() { let _ = a.call("/v1/logout", if all { json!({ "all": true }) } else { json!({}) }, true).await; }
    a.signed_out();
    Ok(json!(true))
}

#[tauri::command]
pub async fn account_remove_device(a: State<'_, Account>, id: String) -> R { need(&a)?; a.call("/v1/logout", json!({ "device": id }), true).await }

#[tauri::command]
pub async fn account_delete(a: State<'_, Account>, password: String) -> R {
    need(&a)?;
    let (auth, _) = keys(password, a.salt(&a.get("login")).await?).await;
    a.call("/v1/delete", json!({ "old": B64.encode(auth) }), true).await?;
    a.signed_out();
    Ok(json!(true))
}

// «На всех устройствах аккаунта»: вход стирается из аккаунта, другие устройства выйдут при синхронизации.
#[tauri::command]
pub fn account_forget(a: State<'_, Account>, svc: String) -> bool {
    if !a.logged() || !SERVICES.contains(&svc.as_str()) { return false; }
    let t = now_ms();
    a.edit(|m| {
        let vt = m.entry("vt").or_insert_with(|| json!({}));
        if !vt.is_object() { *vt = json!({}); }
        vt[svc.as_str()] = t.into();
        let vd = m.entry("vdel").or_insert_with(|| json!({}));
        if !vd.is_object() { *vd = json!({}); }
        vd[svc.as_str()] = true.into();
    });
    true
}

#[tauri::command]
pub async fn account_sync(app: AppHandle, a: State<'_, Account>, state: Value) -> R { a.sync(&app, state).await }
