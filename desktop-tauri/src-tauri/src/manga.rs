// Манга: MangaLib (открытый API, вход через OAuth с PKCE) и Com-X (сайт за проверкой браузера —
// запросы делает сама страница сайта в скрытом окне). Картинки идут через схему mimg: с нужным Referer,
// с кэшем на диске (до 200 МБ), скачанные главы читаются из своей папки. Устроено как в Android-версии.
use crate::{write_private, Yoru, UA};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD as B64, Engine};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet},
    fs,
    path::{Path, PathBuf},
    sync::{atomic::{AtomicU64, Ordering}, Arc, Mutex},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use tauri::{http, webview::NewWindowResponse, AppHandle, Emitter, Manager, State, WebviewUrl, WebviewWindow, WebviewWindowBuilder, WindowEvent};
use tokio::sync::oneshot;

const API: &str = "https://api.cdnlibs.org/api";
const REDIRECT: &str = "https://mangalib.me/ru/front/auth/oauth/callback";
const LIB_LOGIN: &str = "https://auth.lib.social/auth/login";
const COMX: &str = "https://com-x.life/";
// Тот же скрипт, что выполняет Android-версия: список, поиск, страница тайтла и страницы главы.
const COMX_JS: &str = include_str!("../../../android/app/src/main/assets/comx.js");
const CACHE_MAX: u64 = 200 << 20;

pub struct Manga {
    pub(crate) lib: Mutex<Value>,
    pub(crate) comx_ready: tokio::sync::Mutex<bool>,
    seq: AtomicU64,
    writes: AtomicU64,
    cancelled: Mutex<HashSet<String>>,
    root: PathBuf,
}

impl Manga {
    pub fn new(dir: &Path) -> Self {
        let lib = fs::read(dir.join("mangalib.json")).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or(Value::Null);
        let m = Manga { lib: Mutex::new(lib), comx_ready: tokio::sync::Mutex::new(false), seq: AtomicU64::new(1), writes: AtomicU64::new(0), cancelled: Mutex::new(HashSet::new()), root: dir.to_path_buf() };
        let cache = m.cache_dir();
        std::thread::spawn(move || trim(&cache));
        m
    }
    fn cache_dir(&self) -> PathBuf { self.root.join("manga-cache") }
    fn saved_dir(&self) -> PathBuf { self.root.join("manga") }
    fn access(&self) -> String { self.lib.lock().unwrap()["access"].as_str().unwrap_or("").to_string() }
    pub(crate) fn store(&self, v: Value) {
        if v.is_null() { let _ = fs::remove_file(self.root.join("mangalib.json")); }
        else { let _ = write_private(&self.root.join("mangalib.json"), v.to_string().as_bytes()); }
        *self.lib.lock().unwrap() = v;
    }
}

fn now() -> u64 { SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0) }
fn hash(s: &str, n: usize) -> String { Sha256::digest(s.as_bytes()).iter().map(|b| format!("{b:02x}")).collect::<String>()[..n].to_string() }
fn plain(status: u16) -> http::Response<Vec<u8>> { http::Response::builder().status(status).body(Vec::new()).unwrap() }

// ───────────── MangaLib ─────────────
async fn lib_call(y: &Yoru, m: &Manga, method: &str, path: &str, query: &[(String, String)], body: Option<&Value>, auth: bool) -> Result<Value, String> {
    for attempt in 0..2 {
        let token = if auth { m.access() } else { String::new() };
        let url = format!("{API}{path}");
        let mut req = if method == "POST" { y.http.post(&url) } else { y.http.get(&url) };
        req = req.query(query).header("Site-Id", "1").header("Referer", "https://mangalib.me/").header("Accept", "application/json").timeout(Duration::from_secs(30));
        if !token.is_empty() { req = req.bearer_auth(&token); }
        if let Some(b) = body { req = req.json(b); }
        let res = req.send().await.map_err(|_| "Не удалось подключиться к MangaLib. Проверьте интернет.".to_string())?;
        let code = res.status().as_u16();
        if code == 401 && !token.is_empty() && attempt == 0 && refresh(y, m, &token).await { continue; }
        if matches!(code, 403 | 404 | 451) {
            return Err(if token.is_empty() { "MangaLib показывает этот тайтл только после входа. Войдите в MangaLib в разделе «Аккаунты».".into() } else { "MangaLib не отдаёт этот тайтл.".into() });
        }
        if !(200..300).contains(&code) { return Err(format!("MangaLib ответил с ошибкой {code}. Повторите позже.")); }
        return res.json().await.map_err(|_| "MangaLib прислал непонятный ответ. Повторите позже.".to_string());
    }
    Err("MangaLib не ответил. Повторите позже.".into())
}

fn keep(m: &Manga, j: &Value) -> bool {
    let Some(access) = j["access_token"].as_str().filter(|s| !s.is_empty()) else { return false };
    let mut cur = m.lib.lock().unwrap().clone();
    if !cur.is_object() { cur = json!({}); }
    cur["access"] = access.into();
    if let Some(r) = j["refresh_token"].as_str().filter(|s| !s.is_empty()) { cur["refresh"] = r.into(); }
    cur["expires"] = (now() + j["expires_in"].as_u64().unwrap_or(3600)).into();
    m.store(cur);
    crate::account::vault_changed("mangalib");
    true
}

// Обновление входа; если токен уже обновил другой запрос — просто повторяем.
async fn refresh(y: &Yoru, m: &Manga, used: &str) -> bool {
    if m.access() != used { return true; }
    let r = m.lib.lock().unwrap()["refresh"].as_str().unwrap_or("").to_string();
    if r.is_empty() {
        if crate::account::recover("mangalib").await && m.access() != used { return true; }
        m.store(Value::Null);
        return false;
    }
    let body = json!({ "grant_type": "refresh_token", "client_id": "1", "refresh_token": r, "scope": "" });
    match Box::pin(lib_call(y, m, "POST", "/auth/oauth/token", &[], Some(&body), false)).await {
        Ok(j) if keep(m, &j) => true,
        Err(e) if e.starts_with("Не удалось подключиться") => false,
        // Вход перестал работать: возможно, другое устройство уже обновило его в аккаунте Yoru.
        _ => {
            if crate::account::recover("mangalib").await && m.access() != used { return true; }
            m.store(Value::Null);
            false
        }
    }
}

#[tauri::command]
pub async fn manga_lib(y: State<'_, Yoru>, m: State<'_, Manga>, path: String, query: Vec<(String, String)>) -> Result<Value, String> {
    if !path.starts_with("/manga") || path.contains("..") { return Err("Неверный запрос".into()); }
    lib_call(&y, &m, "GET", &path, &query, None, true).await
}

#[tauri::command]
pub fn manga_lib_status(m: State<'_, Manga>) -> Value {
    let l = m.lib.lock().unwrap();
    json!({ "logged": l["access"].as_str().is_some_and(|s| !s.is_empty()), "name": l["name"].as_str().unwrap_or("") })
}

#[tauri::command]
pub fn manga_lib_logout(m: State<'_, Manga>) -> bool { m.store(Value::Null); true }

// Пароль вводится на странице auth.lib.social в отдельном окне, приложение получает только код.
// Окна входа через ВК и другие сервисы открываются в том же окне. С provider ("vkontakte" или "yandex")
// окно сразу переходит со страницы входа MangaLib на вход в этот сервис, а потом сайт сам возвращается к выдаче кода.
#[tauri::command]
pub async fn manga_lib_login(app: AppHandle, y: State<'_, Yoru>, m: State<'_, Manga>, provider: Option<String>) -> Result<String, String> {
    let social = provider.filter(|p| p == "vkontakte" || p == "yandex").map(|p| format!("https://auth.lib.social/auth/oauth/redirect/{p}?intent=login"));
    let social = Arc::new(Mutex::new(social));
    let mut raw = [0u8; 48];
    getrandom::getrandom(&mut raw).map_err(|_| "Не удалось начать вход".to_string())?;
    let verifier = B64.encode(&raw[..32]);
    let state = B64.encode(&raw[32..]);
    let challenge = B64.encode(Sha256::digest(verifier.as_bytes()));
    let mut url = url::Url::parse("https://auth.lib.social/auth/oauth/authorize").unwrap();
    url.query_pairs_mut().append_pair("scope", "").append_pair("client_id", "1").append_pair("response_type", "code")
        .append_pair("redirect_uri", REDIRECT).append_pair("state", &state).append_pair("code_challenge", &challenge)
        .append_pair("code_challenge_method", "S256").append_pair("prompt", "consent");
    if let Some(w) = app.get_webview_window("mangalib-login") { let _ = w.destroy(); }
    let (tx, rx) = oneshot::channel::<Option<String>>();
    let tx = Arc::new(Mutex::new(Some(tx)));
    let (t1, t2, want, h) = (tx.clone(), tx.clone(), state.clone(), app.clone());
    let w = WebviewWindowBuilder::new(&app, "mangalib-login", WebviewUrl::External(url))
        .title("Вход в MangaLib").inner_size(520.0, 760.0).center()
        .on_page_load(move |w, p| {
            if p.event() != tauri::webview::PageLoadEvent::Finished || !p.url().as_str().starts_with(LIB_LOGIN) { return; }
            if let Some(next) = social.lock().unwrap().take().and_then(|s| s.parse::<url::Url>().ok()) { let _ = w.navigate(next); }
        })
        .on_navigation(move |u| {
            if !u.as_str().starts_with(REDIRECT) { return true; }
            let q: HashMap<String, String> = u.query_pairs().into_owned().collect();
            let code = q.get("code").filter(|_| q.get("state") == Some(&want)).cloned();
            if let Some(t) = t1.lock().unwrap().take() { let _ = t.send(code); }
            false
        })
        .on_new_window(move |u, _| {
            let h = h.clone();
            tauri::async_runtime::spawn(async move { if let Some(w) = h.get_webview_window("mangalib-login") { let _ = w.navigate(u); } });
            NewWindowResponse::Deny
        })
        .build().map_err(|e| e.to_string())?;
    w.on_window_event(move |e| if let WindowEvent::Destroyed = e { if let Some(t) = t2.lock().unwrap().take() { let _ = t.send(None); } });
    let code = rx.await.ok().flatten();
    let _ = w.destroy();
    let code = code.ok_or("Вход отменён")?;
    let body = json!({ "grant_type": "authorization_code", "client_id": "1", "redirect_uri": REDIRECT, "code_verifier": verifier, "code": code });
    let j = lib_call(&y, &m, "POST", "/auth/oauth/token", &[], Some(&body), false).await?;
    if !keep(&m, &j) { return Err("MangaLib не выдал вход. Попробуйте ещё раз.".into()); }
    let name = match lib_call(&y, &m, "GET", "/auth/me", &[], None, true).await {
        Ok(me) => me["data"]["username"].as_str().or(me["data"]["name"].as_str()).unwrap_or("Аккаунт").to_string(),
        Err(_) => "Аккаунт".into(),
    };
    let mut cur = m.lib.lock().unwrap().clone();
    cur["name"] = name.clone().into();
    m.store(cur);
    Ok(name)
}

// ───────────── Com-X: скрытое окно с сайтом ─────────────
async fn eval(w: &WebviewWindow, js: String) -> Option<Value> {
    let (tx, rx) = oneshot::channel::<String>();
    let tx = Mutex::new(Some(tx));
    w.eval_with_callback(js, move |s| if let Some(t) = tx.lock().unwrap().take() { let _ = t.send(s); }).ok()?;
    let s = tokio::time::timeout(Duration::from_secs(4), rx).await.ok()?.ok()?;
    serde_json::from_str(&s).ok()
}

fn comx_window(app: &AppHandle) -> Result<WebviewWindow, String> {
    if let Some(w) = app.get_webview_window("comx") { return Ok(w); }
    WebviewWindowBuilder::new(app, "comx", WebviewUrl::External(COMX.parse().unwrap()))
        .title("Com-X").inner_size(1000.0, 760.0).center().visible(false)
        .build().map_err(|_| "Com-X недоступен".to_string())
}

// Страница проверки открывается по тому же адресу; настоящий сайт на DLE объявляет dle_root.
async fn comx_page_ready(w: &WebviewWindow) -> bool {
    eval(w, "location.hostname.endsWith('com-x.life')&&typeof dle_root!=='undefined'&&document.readyState!=='loading'".into()).await == Some(Value::Bool(true))
}

async fn comx_prepare(app: &AppHandle, m: &Manga, reload: bool) -> Result<WebviewWindow, String> {
    let mut ready = m.comx_ready.lock().await;
    let fresh = app.get_webview_window("comx").is_none();
    let w = comx_window(app)?;
    if *ready && !reload && !fresh { return Ok(w); }
    *ready = false;
    if reload || (!fresh && !comx_page_ready(&w).await) { let _ = w.navigate(COMX.parse().unwrap()); }
    let start = Instant::now();
    let mut shown = false;
    while start.elapsed() < Duration::from_secs(if shown { 120 } else { 40 }) {
        tokio::time::sleep(Duration::from_millis(600)).await;
        if comx_page_ready(&w).await {
            *ready = true;
            if shown { let _ = w.hide(); }
            return Ok(w);
        }
        // Сайт долго проверяет браузер — показываем окно: иногда нужно нажать «Я не робот».
        if !shown && start.elapsed() > Duration::from_secs(12) && app.get_webview_window("comx").is_some() {
            shown = true;
            let _ = w.set_title("Com-X проверяет браузер — дождитесь открытия сайта");
            let _ = w.show();
        }
        if app.get_webview_window("comx").is_none() { break; }
    }
    Err("Com-X не открылся: сайт долго проверяет браузер. Повторите позже.".into())
}

pub async fn comx_run(app: &AppHandle, m: &Manga, args: &Value) -> Result<Value, String> {
    for attempt in 0..2 {
        let w = comx_prepare(app, m, attempt > 0).await?;
        let id = m.seq.fetch_add(1, Ordering::Relaxed);
        let put = format!("(window.__yoruR||(window.__yoruR={{}}))[{id}]");
        let js = format!("(async()=>{{const args={args};try{{const r=await(async()=>{{{COMX_JS}\n}})();{put}=JSON.stringify(r)}}catch(e){{{put}=JSON.stringify({{error:String(e)}})}}}})();void 0;");
        if w.eval(js).is_err() { continue; }
        let start = Instant::now();
        while start.elapsed() < Duration::from_secs(40) {
            tokio::time::sleep(Duration::from_millis(200)).await;
            let got = eval(&w, format!("(function(){{var r=window.__yoruR&&window.__yoruR[{id}];if(r)delete window.__yoruR[{id}];return r||null}})()")).await;
            let Some(Value::String(s)) = got else { continue };
            let o: Value = serde_json::from_str(&s).unwrap_or(Value::Null);
            if o.is_object() && o.get("challenge").is_none() && o.get("error").is_none() { return Ok(o); }
            break;
        }
        *m.comx_ready.lock().await = false;
    }
    Err("Com-X не ответил. Повторите позже.".into())
}

#[tauri::command]
pub async fn comx(app: AppHandle, m: State<'_, Manga>, args: Value) -> Result<Value, String> {
    if !args["op"].as_str().is_some_and(|o| ["list", "search", "details", "pages"].contains(&o)) { return Err("Неверный запрос".into()); }
    comx_run(&app, &m, &args).await
}

pub(crate) fn comx_cookies(app: &AppHandle) -> Vec<tauri::webview::Cookie<'static>> {
    let w = app.get_webview_window("comx").or_else(|| app.get_webview_window("main"));
    w.and_then(|w| w.cookies_for_url(COMX.parse().unwrap()).ok()).unwrap_or_default()
}
// После входа на com-x.life DLE ставит cookie dle_user_id.
pub(crate) fn comx_logged(app: &AppHandle) -> bool {
    comx_cookies(app).iter().any(|c| c.name() == "dle_user_id" && !["", "0", "deleted"].contains(&c.value()))
}

#[tauri::command]
pub async fn comx_status(app: AppHandle) -> bool { comx_logged(&app) }

// Вход: окно сайта показывается пользователю, он входит сам; ждём cookie или закрытия окна.
#[tauri::command]
pub async fn comx_login(app: AppHandle, m: State<'_, Manga>) -> Result<bool, String> {
    *m.comx_ready.lock().await = false;
    let w = comx_window(&app)?;
    let _ = w.navigate(COMX.parse().unwrap());
    let _ = w.set_title("Вход в Com-X — войдите через кнопку «Войти» на сайте, окно закроется само");
    let _ = w.show();
    let _ = w.set_focus();
    let start = Instant::now();
    while start.elapsed() < Duration::from_secs(900) {
        tokio::time::sleep(Duration::from_secs(1)).await;
        if app.get_webview_window("comx").is_none() {
            let ok = comx_logged(&app);
            if ok { crate::account::vault_changed("comx"); }
            return Ok(ok);
        }
        if comx_logged(&app) { let _ = w.hide(); crate::account::vault_changed("comx"); return Ok(true); }
    }
    let _ = w.hide();
    Ok(comx_logged(&app))
}

#[tauri::command]
pub async fn comx_logout(app: AppHandle, m: State<'_, Manga>) -> Result<bool, String> {
    if let Some(w) = app.get_webview_window("comx").or_else(|| app.get_webview_window("main")) {
        for c in comx_cookies(&app) {
            if c.name().starts_with("dle_") || c.name() == "PHPSESSID" { let _ = w.delete_cookie(c); }
        }
    }
    *m.comx_ready.lock().await = false;
    Ok(!comx_logged(&app))
}

// ───────────── Картинки ─────────────
fn manga_host(u: &url::Url) -> bool {
    u.scheme() == "https" && u.host_str().is_some_and(|h| ["cdnlibs", "com-x", "mangalib", "imglib", "cdnrulib", "lib.social"].iter().any(|k| h.contains(k)))
}
fn referer(u: &url::Url) -> &'static str { if u.host_str().is_some_and(|h| h.contains("com-x")) { COMX } else { "https://mangalib.me/" } }
fn kind(b: &[u8]) -> &'static str {
    if b.starts_with(&[0x89, b'P', b'N', b'G']) { "image/png" }
    else if b.starts_with(b"GIF8") { "image/gif" }
    else if b.len() > 12 && &b[..4] == b"RIFF" && &b[8..12] == b"WEBP" { "image/webp" }
    else if b.len() > 12 && &b[4..8] == b"ftyp" && (&b[8..12] == b"avif" || &b[8..12] == b"avis") { "image/avif" }
    else { "image/jpeg" }
}
fn ext(u: &str) -> &'static str {
    let p = u.split(['?', '#']).next().unwrap_or("").to_ascii_lowercase();
    ["png", "webp", "gif", "jpeg", "jpg", "avif"].into_iter().find(|e| p.ends_with(&format!(".{e}"))).unwrap_or("jpg")
}

// Три попытки с паузой: сервера картинок иногда обрывают соединение.
async fn fetch_image(http: &reqwest::Client, u: &url::Url) -> Result<Vec<u8>, String> {
    let mut last = String::new();
    for attempt in 1..=3u64 {
        let r = async {
            let res = http.get(u.clone()).header("Referer", referer(u)).header("Accept", "image/avif,image/webp,image/*,*/*").header("User-Agent", UA)
                .timeout(Duration::from_secs(45)).send().await.map_err(|_| "нет сети".to_string())?;
            if !res.status().is_success() { return Err(format!("HTTP {}", res.status().as_u16())); }
            let b = res.bytes().await.map_err(|_| "обрыв".to_string())?;
            if b.len() <= 100 || b.len() > 40 << 20 { return Err("пустой файл".into()); }
            Ok(b.to_vec())
        }.await;
        match r { Ok(b) => return Ok(b), Err(e) => last = e }
        tokio::time::sleep(Duration::from_millis(500 * attempt)).await;
    }
    Err(format!("Страница не загрузилась ({last}). Проверьте интернет."))
}

fn trim(dir: &Path) {
    let Ok(rd) = fs::read_dir(dir) else { return };
    let mut files: Vec<(SystemTime, u64, PathBuf)> = rd.flatten().filter_map(|e| { let m = e.metadata().ok()?; Some((m.modified().ok()?, m.len(), e.path())) }).collect();
    files.sort_by(|a, b| b.0.cmp(&a.0));
    let mut total = 0;
    for (_, len, p) in files { total += len; if total > CACHE_MAX || p.extension().is_some_and(|e| e == "tmp") { let _ = fs::remove_file(p); } }
}

fn image_response(body: Vec<u8>) -> http::Response<Vec<u8>> {
    http::Response::builder().status(200).header("Content-Type", kind(&body)).header("Content-Length", body.len().to_string())
        .header("Cache-Control", "max-age=86400").header("Access-Control-Allow-Origin", "*").body(body).unwrap()
}

// mimg://x/i/<адрес в base64url> — страница или обложка из сети; mimg://x/f/<тайтл>/<глава>/<файл> — скачанная.
// На Windows та же схема видна как http://mimg.localhost/…
pub async fn serve(app: AppHandle, req: http::Request<Vec<u8>>) -> http::Response<Vec<u8>> {
    let path = req.uri().path().to_string();
    let parts: Vec<&str> = path.trim_start_matches('/').split('/').collect();
    let m = app.state::<Manga>();
    match parts.as_slice() {
        ["f", t, c, name] => {
            if [t, c, name].iter().any(|s| s.is_empty() || s.starts_with('.') || s.contains('\\')) { return plain(404); }
            match fs::read(m.saved_dir().join(t).join(c).join(name)) { Ok(b) => image_response(b), Err(_) => plain(404) }
        }
        ["i", enc] => {
            let Some(u) = B64.decode(enc).ok().and_then(|b| String::from_utf8(b).ok()).and_then(|s| url::Url::parse(&s).ok()).filter(manga_host) else { return plain(404) };
            let dir = m.cache_dir();
            let f = dir.join(hash(u.as_str(), 32));
            if let Ok(b) = fs::read(&f) { if b.len() > 100 { return image_response(b); } }
            let http = app.state::<Yoru>().http.clone();
            match fetch_image(&http, &u).await {
                Ok(b) => {
                    let _ = fs::create_dir_all(&dir);
                    let tmp = f.with_extension(format!("{}.tmp", m.seq.fetch_add(1, Ordering::Relaxed)));
                    if fs::write(&tmp, &b).is_ok() && fs::rename(&tmp, &f).is_err() { let _ = fs::remove_file(&tmp); }
                    if m.writes.fetch_add(1, Ordering::Relaxed) % 100 == 99 { std::thread::spawn(move || trim(&dir)); }
                    image_response(b)
                }
                Err(_) => plain(502),
            }
        }
        _ => plain(404),
    }
}

// ───────────── Скачанные главы ─────────────
// manga/<тайтл>/<глава>/001.jpg… + pages.json; title.json — страница тайтла для чтения без сети.
fn item_id(details: &Value) -> String { format!("{}:{}", details["item"]["source"].as_str().unwrap_or(""), details["item"]["key"].as_str().unwrap_or("")) }
fn ch_id(ch: &Value) -> String { match &ch["id"] { Value::String(s) => s.clone(), v => v.to_string() } }
fn title_dir(m: &Manga, id: &str) -> PathBuf { m.saved_dir().join(hash(id, 20)) }
fn pages_of(dir: &Path) -> Option<Vec<String>> { serde_json::from_slice(&fs::read(dir.join("pages.json")).ok()?).ok() }
fn tree_size(p: &Path) -> u64 {
    match fs::metadata(p) { Ok(md) if md.is_file() => md.len(), Ok(_) => fs::read_dir(p).map(|r| r.flatten().map(|e| tree_size(&e.path())).sum()).unwrap_or(0), _ => 0 }
}

#[tauri::command]
pub async fn manga_save(app: AppHandle, y: State<'_, Yoru>, m: State<'_, Manga>, details: Value, chapter: Value, urls: Vec<String>) -> Result<(), String> {
    let (id, cid) = (item_id(&details), ch_id(&chapter));
    let key = format!("{id}|{cid}");
    let tdir = title_dir(&m, &id);
    let cname = hash(&cid, 20);
    fs::create_dir_all(&tdir).map_err(|e| e.to_string())?;
    let _ = fs::write(tdir.join("title.json"), details.to_string());
    let tmp = tdir.join(format!("{cname}.part"));
    let _ = fs::remove_dir_all(&tmp);
    fs::create_dir_all(&tmp).map_err(|e| e.to_string())?;
    let parsed: Vec<url::Url> = urls.iter().filter_map(|u| url::Url::parse(u).ok()).filter(manga_host).collect();
    if parsed.is_empty() || parsed.len() != urls.len() { let _ = fs::remove_dir_all(&tmp); return Err("В этой главе нет страниц".into()); }
    let total = parsed.len();
    let names: Vec<String> = parsed.iter().enumerate().map(|(i, u)| format!("{:03}.{}", i + 1, ext(u.as_str()))).collect();
    let result: Result<(), String> = async {
        let mut done = 0;
        // По четыре страницы одновременно.
        for chunk in parsed.iter().zip(&names).collect::<Vec<_>>().chunks(4) {
            if m.cancelled.lock().unwrap().contains(&key) { return Err("Отменено".into()); }
            let mut set = tokio::task::JoinSet::new();
            for (u, name) in chunk {
                let (http, f, u) = (y.http.clone(), tmp.join(name), (*u).clone());
                set.spawn(async move { fs::write(&f, fetch_image(&http, &u).await?).map_err(|_| "Не удалось сохранить страницу".to_string()) });
            }
            while let Some(r) = set.join_next().await { r.map_err(|_| "Не удалось скачать главу".to_string())??; done += 1; }
            let _ = app.emit("mangaDl", json!({ "key": key, "done": done, "total": total }));
        }
        fs::write(tmp.join("pages.json"), serde_json::to_string(&names).unwrap()).map_err(|e| e.to_string())?;
        let target = tdir.join(&cname);
        let _ = fs::remove_dir_all(&target);
        fs::rename(&tmp, &target).map_err(|_| "Не удалось сохранить главу".to_string())
    }.await;
    let _ = fs::remove_dir_all(&tmp);
    m.cancelled.lock().unwrap().remove(&key);
    result
}

#[tauri::command]
pub fn manga_cancel(m: State<'_, Manga>, id: String, chapter: String) { m.cancelled.lock().unwrap().insert(format!("{id}|{chapter}")); }

// Скачанные тайтлы, новые первыми: страница тайтла, какие главы готовы и сколько места занято.
#[tauri::command]
pub fn manga_saved(m: State<'_, Manga>) -> Vec<Value> {
    let Ok(rd) = fs::read_dir(m.saved_dir()) else { return vec![] };
    let mut dirs: Vec<(SystemTime, PathBuf)> = rd.flatten().filter(|e| e.path().is_dir()).map(|e| (e.metadata().and_then(|m| m.modified()).unwrap_or(UNIX_EPOCH), e.path())).collect();
    dirs.sort_by(|a, b| b.0.cmp(&a.0));
    let mut out = vec![];
    for (_, d) in dirs {
        let Some(details) = fs::read(d.join("title.json")).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok()) else { continue };
        let tname = d.file_name().unwrap().to_string_lossy().to_string();
        let mut chapters = serde_json::Map::new();
        for ch in details["chapters"].as_array().into_iter().flatten() {
            let cname = hash(&ch_id(ch), 20);
            if let Some(files) = pages_of(&d.join(&cname)) {
                chapters.insert(ch_id(ch), files.iter().map(|f| format!("f/{tname}/{cname}/{f}")).collect::<Vec<_>>().into());
            }
        }
        out.push(json!({ "details": details, "chapters": chapters, "size": tree_size(&d) }));
    }
    out
}

#[tauri::command]
pub fn manga_delete(m: State<'_, Manga>, id: String, chapter: Option<String>) {
    let d = title_dir(&m, &id);
    match chapter {
        Some(c) => {
            let _ = fs::remove_dir_all(d.join(hash(&c, 20)));
            let left = fs::read_dir(&d).map(|r| r.flatten().any(|e| e.path().is_dir())).unwrap_or(false);
            if !left { let _ = fs::remove_dir_all(&d); }
        }
        None => { let _ = fs::remove_dir_all(&d); }
    }
}
