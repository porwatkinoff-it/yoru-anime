// Серии для просмотра без интернета — как desktop/src/downloads.js в Electron-версии, с тем же index.json,
// поэтому загрузки из 2.0.x остаются на месте. Ссылка на видео берётся заново при каждом запуске загрузки
// (ссылки сайта быстро устаревают), а недокачанный .part продолжается с того же места.
use crate::{call_api, Yoru, BASE};
use serde_json::{json, Map, Value};
use std::{
    fs,
    future::Future,
    io::{self, BufWriter, Read, Seek, SeekFrom, Write},
    path::{Path, PathBuf},
    sync::{Arc, Mutex, OnceLock},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use tauri::{http, AppHandle, Emitter, Manager};
use tokio::sync::Notify;

pub struct Dl {
    dir: PathBuf,
    items: Mutex<Vec<Value>>,
    active: Mutex<Option<(i64, Arc<Notify>)>>,
    battery: OnceLock<bool>,
}

fn now_ms() -> u64 { SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0) }
fn num(v: &Value) -> f64 { v.as_f64().or_else(|| v.as_str().and_then(|s| s.trim().parse().ok())).unwrap_or(0.0) }
fn key(v: &Value) -> i64 { v.as_i64().unwrap_or_else(|| num(v) as i64) }
fn text(v: &Value) -> String { v.as_str().unwrap_or("").to_string() }

impl Dl {
    pub fn new(dir: PathBuf) -> Self {
        let _ = fs::create_dir_all(&dir);
        let mut items: Vec<Value> = fs::read(dir.join("index.json")).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default();
        // После перезапуска незаконченные снова встают в очередь.
        for d in items.iter_mut().filter(|d| d["state"] == "running") { d["state"] = "queued".into(); }
        Dl { dir, items: Mutex::new(items), active: Mutex::new(None), battery: OnceLock::new() }
    }
    fn file(&self, name: &str) -> PathBuf { self.dir.join(Path::new(name).file_name().unwrap_or_default()) }
    fn get(&self, id: i64) -> Option<Value> { self.items.lock().unwrap().iter().find(|d| key(&d["id"]) == id).cloned() }
    fn update(&self, id: i64, f: impl FnOnce(&mut Value)) -> bool {
        let mut items = self.items.lock().unwrap();
        match items.iter_mut().find(|d| key(&d["id"]) == id) { Some(d) => { f(d); true } None => false }
    }
    fn save(&self) {
        let body = serde_json::to_vec(&*self.items.lock().unwrap()).unwrap_or_default();
        let f = self.dir.join("index.json");
        let tmp = self.dir.join("index.json.tmp");
        if fs::write(&tmp, body).is_ok() { let _ = fs::rename(tmp, f); }
    }
}

// Список уходит одним аргументом: мост раскрывает массивы в аргументы обработчика.
fn publish(app: &AppHandle) {
    let items = app.state::<Dl>().items.lock().unwrap().clone();
    let _ = app.emit("dlChanged", json!([items]));
}
fn changed(app: &AppHandle) { app.state::<Dl>().save(); publish(app); }

// ---------- Батарея ----------
fn battery() -> bool {
    #[cfg(target_os = "macos")]
    { std::process::Command::new("/usr/bin/pmset").args(["-g", "batt"]).output().is_ok_and(|o| String::from_utf8_lossy(&o.stdout).contains("InternalBattery")) }
    #[cfg(windows)]
    {
        use windows_sys::Win32::System::Power::{GetSystemPowerStatus, SYSTEM_POWER_STATUS};
        let mut s: SYSTEM_POWER_STATUS = unsafe { std::mem::zeroed() };
        // 128 — батареи нет, 255 — неизвестно.
        unsafe { GetSystemPowerStatus(&mut s) != 0 && s.BatteryFlag != 128 && s.BatteryFlag != 255 }
    }
    #[cfg(not(any(target_os = "macos", windows)))]
    {
        fs::read_dir("/sys/class/power_supply").map(|r| r.flatten().any(|e| fs::read_to_string(e.path().join("type")).is_ok_and(|t| t.trim() == "Battery"))).unwrap_or(false)
    }
}

fn free_space(p: &Path) -> u64 {
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStrExt;
        let Ok(c) = std::ffi::CString::new(p.as_os_str().as_bytes()) else { return 0 };
        let mut s: libc::statvfs = unsafe { std::mem::zeroed() };
        if unsafe { libc::statvfs(c.as_ptr(), &mut s) } == 0 { s.f_bavail as u64 * s.f_frsize as u64 } else { 0 }
    }
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        let w: Vec<u16> = p.as_os_str().encode_wide().chain(std::iter::once(0)).collect();
        let mut free: u64 = 0;
        unsafe { windows_sys::Win32::Storage::FileSystem::GetDiskFreeSpaceExW(w.as_ptr(), &mut free, std::ptr::null_mut(), std::ptr::null_mut()) };
        free
    }
}

// ---------- Очередь ----------
enum E { Status(u16), NoSpace, BadSubs, Net, User(String), Aborted, Other }
impl E {
    fn message(&self) -> String {
        match self {
            E::Status(403 | 404 | 410) => "Ссылка устарела — нажмите, чтобы повторить".into(),
            E::NoSpace => "Не хватает места на устройстве".into(),
            E::BadSubs => "Субтитры не скачались — нажмите, чтобы повторить".into(),
            E::Net => "Нет сети — повторите позже".into(),
            E::User(m) => m.clone(),
            _ => "Загрузка прервалась".into(),
        }
    }
}
fn io_err(e: io::Error) -> E {
    if e.kind() == io::ErrorKind::StorageFull || matches!(e.raw_os_error(), Some(28) | Some(112)) { E::NoSpace } else { E::Other }
}
fn net_err(e: reqwest::Error) -> E { if e.is_connect() || e.is_timeout() { E::Net } else { E::Other } }

async fn cancellable<F: Future>(c: &Notify, f: F) -> Result<F::Output, E> {
    tokio::select! { r = f => Ok(r), _ = c.notified() => Err(E::Aborted) }
}

fn pick_stream(embed: &Value, quality: f64) -> Option<(f64, String)> {
    let arr = |k: &str| embed[k].as_array().cloned().unwrap_or_default();
    let mut list: Vec<(f64, String)> = arr("stream").iter().map(|s| (num(&s["height"]), text(&s["urls"][0]))).filter(|s| !s.1.is_empty()).collect();
    // Запасной вариант — ссылки «download»: без входа на сайте в браузере они часто дают 403.
    if list.is_empty() { list = arr("download").iter().map(|s| (num(&s["height"]), text(&s["url"]))).filter(|s| !s.1.is_empty()).collect(); }
    list.sort_by(|a, b| b.0.total_cmp(&a.0));
    list.iter().find(|s| s.0 <= quality).or(list.last()).cloned()
}

async fn fetch_subs(http: &reqwest::Client, url: &str, c: &Notify) -> Result<(String, &'static str), E> {
    let u = url::Url::parse(BASE).unwrap().join(url).map_err(|_| E::BadSubs)?;
    let res = cancellable(c, http.get(u).send()).await?.map_err(|_| E::Net)?;
    if !res.status().is_success() { return Err(E::Status(res.status().as_u16())); }
    let b = cancellable(c, res.bytes()).await?.map_err(net_err)?;
    if b.len() > 8 << 20 { return Err(E::BadSubs); }
    let mut t = String::from_utf8_lossy(&b).into_owned();
    if t.contains('\u{FFFD}') { t = encoding_rs::WINDOWS_1251.decode(&b).0.into_owned(); }
    if t.contains("[Events]") { return Ok((t, "ass")); }
    if t.contains("-->") { let vtt = t.trim_start_matches('\u{FEFF}').starts_with("WEBVTT"); return Ok((t, if vtt { "vtt" } else { "srt" })); }
    Err(E::BadSubs)
}

async fn fetch(app: &AppHandle, id: i64, c: &Notify) -> Result<(), E> {
    let y = app.state::<Yoru>();
    let dl = app.state::<Dl>();
    let d = dl.get(id).ok_or(E::Aborted)?;
    let path = format!("translations/embed/{}", crate::param(&d["translationId"]).unwrap_or_default());
    let embed = cancellable(c, call_api(&y, &path, &Map::new(), true)).await?.map_err(E::User)?;
    let (height, link) = pick_stream(&embed, num(&d["quality"])).ok_or_else(|| E::User("Сайт не вернул видео для этого перевода".into()))?;
    // Субтитры — первыми: серия с субтитрами без них бесполезна.
    let mut subtitles = text(&d["subtitles"]);
    if let Some(u) = embed["subtitlesUrl"].as_str().filter(|u| !u.is_empty()) {
        if subtitles.is_empty() {
            let (t, ext) = fetch_subs(&y.http, u, c).await?;
            subtitles = format!("{id}.{ext}");
            fs::write(dl.file(&subtitles), t).map_err(io_err)?;
            let s = subtitles.clone();
            dl.update(id, |d| d["subtitles"] = s.into());
        }
    }
    if text(&d["translationKind"]).starts_with("sub") && subtitles.is_empty() { return Err(E::User("Для этого перевода нет субтитров".into())); }
    // Другое качество — другой файл: начинаем заново.
    let video = text(&d["video"]);
    let part = dl.file(&format!("{video}.part"));
    if num(&d["height"]) != 0.0 && num(&d["height"]) != height { let _ = fs::remove_file(&part); }
    dl.update(id, |d| d["height"] = json!(height as i64));
    let mut have = fs::metadata(&part).map(|m| m.len()).unwrap_or(0);
    let site = url::Url::parse(BASE).unwrap().join(&link).map_err(|_| E::User("Сайт не вернул видео для этого перевода".into()))?;
    let get = |u: url::Url| { let r = y.http.get(u); if have > 0 { r.header("Range", format!("bytes={have}-")) } else { r } };
    // Через самый быстрый из проверенных серверов; не ответил — по ссылке сайта.
    let server = text(&d["server"]);
    let mut res = None;
    if !server.is_empty() && site.host_str().is_some_and(|h| h.starts_with("ru-") && h != server) {
        let mut fast = site.clone();
        if fast.set_host(Some(&server)).is_ok() {
            if let Ok(r) = cancellable(c, get(fast).send()).await? { if r.status().is_success() { res = Some(r); } }
        }
        if res.is_none() { let _ = app.emit("serverFailed", &server); dl.update(id, |d| d["server"] = "".into()); }
    }
    let mut res = match res { Some(r) => r, None => cancellable(c, get(site).send()).await?.map_err(|_| E::Net)? };
    let status = res.status().as_u16();
    if status == 416 { let _ = fs::remove_file(&part); return Err(E::Status(410)); }
    if !res.status().is_success() { return Err(E::Status(status)); }
    if status != 206 { have = 0; }
    let len = res.content_length().unwrap_or(0);
    let total = if len > 0 { have + len } else { 0 };
    let mut bytes = have;
    dl.update(id, |d| { d["total"] = json!(total); d["bytes"] = json!(bytes); });
    publish(app);
    let f = fs::OpenOptions::new().create(true).write(true).append(have > 0).truncate(have == 0).open(&part).map_err(io_err)?;
    let mut out = BufWriter::with_capacity(1 << 20, f);
    let mut last = Instant::now();
    while let Some(chunk) = cancellable(c, res.chunk()).await?.map_err(net_err)? {
        out.write_all(&chunk).map_err(io_err)?;
        bytes += chunk.len() as u64;
        // Проценты в окно — раз в секунду.
        if last.elapsed() >= Duration::from_secs(1) {
            last = Instant::now();
            dl.update(id, |d| d["bytes"] = json!(bytes));
            publish(app);
        }
    }
    out.into_inner().map_err(|e| io_err(e.into_error()))?.sync_all().map_err(io_err)?;
    if total > 0 && bytes < total { return Err(E::Other); }
    fs::rename(&part, dl.file(&video)).map_err(io_err)?;
    dl.update(id, |d| { d["state"] = "done".into(); d["bytes"] = json!(bytes); d["total"] = json!(bytes); d["finished"] = json!(now_ms()); });
    changed(app);
    if let Some(d) = dl.get(id) { let _ = app.emit("dlDone", d); }
    Ok(())
}

async fn run(app: AppHandle, id: i64, c: Arc<Notify>) {
    let dl = app.state::<Dl>();
    dl.update(id, |d| { d["state"] = "running".into(); d["error"] = "".into(); });
    changed(&app);
    if let Err(e) = fetch(&app, id, &c).await {
        let aborted = matches!(e, E::Aborted);
        let exists = dl.update(id, |d| { if aborted { d["state"] = "queued".into() } else { d["state"] = "failed".into(); d["error"] = e.message().into(); } });
        if !exists {
            // Удалили во время загрузки: на Windows открытый файл не удалить сразу, добиваем здесь.
            let _ = fs::remove_file(dl.file(&format!("{id}.mp4.part")));
        } else if !aborted { changed(&app); }
    }
    { let mut a = dl.active.lock().unwrap(); if a.as_ref().is_some_and(|x| x.0 == id) { *a = None; } }
    next(&app);
}

pub fn next(app: &AppHandle) {
    let dl = app.state::<Dl>();
    let mut active = dl.active.lock().unwrap();
    if active.is_some() { return; }
    let Some(id) = dl.items.lock().unwrap().iter().find(|d| d["state"] == "queued").map(|d| key(&d["id"])) else { return };
    let c = Arc::new(Notify::new());
    *active = Some((id, c.clone()));
    tauri::async_runtime::spawn(run(app.clone(), id, c));
}

pub fn start(app: &AppHandle) { publish(app); next(app); }

fn remove(app: &AppHandle, ids: &[i64]) {
    let dl = app.state::<Dl>();
    for &id in ids {
        if let Some((a, c)) = dl.active.lock().unwrap().as_ref() { if *a == id { c.notify_one(); } }
        let gone = { let mut items = dl.items.lock().unwrap(); items.iter().position(|d| key(&d["id"]) == id).map(|i| items.remove(i)) };
        if let Some(d) = gone {
            let video = text(&d["video"]);
            for f in [video.clone(), format!("{video}.part"), text(&d["subtitles"])] { if !f.is_empty() { let _ = fs::remove_file(dl.file(&f)); } }
        }
    }
    changed(app);
}

// ---------- Команды для интерфейса ----------
#[tauri::command]
pub async fn has_battery(app: AppHandle) -> bool { *app.state::<Dl>().battery.get_or_init(battery) }

#[tauri::command]
pub async fn dl_list(app: AppHandle) -> Vec<Value> { app.state::<Dl>().items.lock().unwrap().clone() }

#[tauri::command]
pub async fn dl_enqueue(app: AppHandle, meta: Value) -> Result<Value, String> {
    let dl = app.state::<Dl>();
    let id = key(&meta["id"]);
    if let Some(old) = dl.get(id) {
        if old["state"] != "failed" { return Ok(old); }
        remove(&app, &[id]);
    }
    let m = |k: &str| meta.get(k).cloned().unwrap_or(Value::Null);
    let quality = if num(&meta["quality"]) > 0.0 { m("quality") } else { json!(720) };
    let d = json!({
        "id": m("id"), "seriesId": m("seriesId"), "series": m("series"), "episodeTitle": m("episodeTitle"), "episodeNumber": m("episodeNumber"),
        "translationId": m("translationId"), "translationTitle": m("translationTitle"), "translationKind": m("translationKind"), "translationSignature": m("translationSignature"),
        "quality": quality, "server": text(&meta["server"]), "height": 0, "video": format!("{id}.mp4"), "subtitles": "", "bytes": 0, "total": 0,
        "state": "queued", "error": "", "created": now_ms()
    });
    dl.items.lock().unwrap().push(d.clone());
    changed(&app);
    next(&app);
    Ok(d)
}

#[tauri::command]
pub async fn dl_retry(app: AppHandle, id: Value) {
    let dl = app.state::<Dl>();
    let id = key(&id);
    if dl.get(id).is_some_and(|d| d["state"] == "failed") {
        dl.update(id, |d| { d["state"] = "queued".into(); d["error"] = "".into(); });
        changed(&app);
        next(&app);
    }
}

#[tauri::command]
pub async fn dl_remove(app: AppHandle, ids: Value) {
    let ids: Vec<i64> = match &ids { Value::Array(a) => a.iter().map(key).collect(), v => vec![key(v)] };
    remove(&app, &ids);
}

#[tauri::command]
pub async fn dl_text(app: AppHandle, id: Value) -> Result<String, String> {
    let dl = app.state::<Dl>();
    let name = dl.get(key(&id)).map(|d| text(&d["subtitles"])).filter(|s| !s.is_empty()).ok_or("Нет субтитров")?;
    let b = fs::read(dl.file(&name)).map_err(|e| e.to_string())?;
    Ok(String::from_utf8_lossy(&b).into_owned())
}

#[tauri::command]
pub async fn dl_space(app: AppHandle) -> Value {
    let dl = app.state::<Dl>();
    let used: f64 = dl.items.lock().unwrap().iter().map(|d| num(&d["bytes"])).sum();
    json!({ "used": used, "free": free_space(&dl.dir) })
}

// ---------- Файлы для плеера ----------
// yoru://dl/<имя> (на Windows — http://yoru.localhost/dl/<имя>) с перемоткой (Range).
// Ответ целиком в памяти, поэтому отдаём куски не больше 2 МБ: плеер сам просит следующие.
pub fn serve(app: &AppHandle, req: &http::Request<Vec<u8>>) -> http::Response<Vec<u8>> {
    let plain = |status: u16| http::Response::builder().status(status).body(Vec::new()).unwrap();
    let raw = req.uri().path().rsplit('/').next().unwrap_or("");
    let name = percent_encoding::percent_decode_str(raw).decode_utf8_lossy().to_string();
    if name.is_empty() || name.contains(['/', '\\']) || name.starts_with('.') { return plain(404); }
    let f = app.state::<Dl>().dir.join(&name);
    let Ok(mut file) = fs::File::open(&f) else { return plain(404) };
    let size = file.metadata().map(|m| m.len()).unwrap_or(0);
    let range = req.headers().get("range").and_then(|v| v.to_str().ok()).and_then(|r| r.trim().strip_prefix("bytes=")).and_then(|r| r.split(',').next()).and_then(|r| r.split_once('-'));
    const MAX: u64 = 2 << 20;
    let (mut start, mut end, mut partial) = (0u64, size.saturating_sub(1), false);
    if let Some((a, b)) = range {
        let (a, b) = (a.trim().parse::<u64>().ok(), b.trim().parse::<u64>().ok());
        start = match (a, b) { (Some(a), _) => a, (None, Some(b)) => size.saturating_sub(b), _ => 0 };
        end = match (a, b) { (Some(_), Some(b)) => b.min(size.saturating_sub(1)), _ => size.saturating_sub(1) };
        if size == 0 || start > end || start >= size {
            return http::Response::builder().status(416).header("Content-Range", format!("bytes */{size}")).body(Vec::new()).unwrap();
        }
        partial = true;
    }
    if size > MAX { partial = true; }
    if partial { end = end.min(start + MAX - 1); }
    let mut body = Vec::new();
    if size > 0 && (file.seek(SeekFrom::Start(start)).is_err() || file.take(end - start + 1).read_to_end(&mut body).is_err()) { return plain(500); }
    let kind = if name.ends_with(".mp4") { "video/mp4" } else { "text/plain; charset=utf-8" };
    let mut r = http::Response::builder().status(if partial { 206 } else { 200 })
        .header("Content-Type", kind).header("Content-Length", body.len().to_string()).header("Accept-Ranges", "bytes")
        .header("Access-Control-Allow-Origin", "*");
    if partial { r = r.header("Content-Range", format!("bytes {start}-{}/{size}", start + body.len() as u64 - 1)); }
    r.body(body).unwrap()
}
