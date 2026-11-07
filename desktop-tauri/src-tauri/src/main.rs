// Yoru Anime для компьютера на Rust (Tauri) с системным WebView. Интерфейс общий с Electron-версией (desktop/src/ui).
// Сеть идёт отсюда: у сайта нет CORS, а токен не попадает в страницу.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod dl;
#[cfg(not(target_os = "macos"))]
mod migrate;
mod update;

use serde_json::{json, Map, Value};
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
    process::Command,
    sync::{atomic::{AtomicBool, Ordering}, Mutex},
    time::{Duration, Instant},
};
use tauri::{webview::PageLoadEvent, AppHandle, Emitter, Manager, RunEvent, State, WebviewUrl, WebviewWindow, WebviewWindowBuilder, WindowEvent};

pub const BASE: &str = "https://smotret-anime.app";
#[cfg(target_os = "macos")]
pub const UA: &str = "NightAnime/1.0 (macOS)";
#[cfg(windows)]
pub const UA: &str = "NightAnime/1.0 (Windows)";
#[cfg(not(any(target_os = "macos", windows)))]
pub const UA: &str = "NightAnime/1.0 (Linux)";

pub struct Yoru {
    token: Mutex<String>,
    pub http: reqwest::Client,
    dir: PathBuf,
}

// Файл с правами только для этого пользователя, через временный — чтобы не оставить половину.
fn write_private(f: &Path, data: &[u8]) -> std::io::Result<()> {
    let tmp = f.with_extension("tmp");
    let mut o = fs::OpenOptions::new();
    o.write(true).create(true).truncate(true);
    #[cfg(unix)]
    { use std::os::unix::fs::OpenOptionsExt; o.mode(0o600); }
    o.open(&tmp)?.write_all(data)?;
    fs::rename(tmp, f)
}

impl Yoru {
    fn save_token(&self, t: &str) {
        if t.is_empty() {
            let _ = fs::remove_file(self.dir.join("token"));
            let _ = fs::remove_file(self.dir.join("token.bin"));
            return;
        }
        let _ = fs::create_dir_all(&self.dir);
        let _ = write_private(&self.dir.join("token"), t.as_bytes());
    }
}

// Вход из 2.0.x: на Mac токен уже лежит в том же файле, на Windows и Linux его нужно расшифровать.
fn read_token(dir: &Path) -> String {
    let t = fs::read_to_string(dir.join("token")).map(|t| t.trim().to_string()).unwrap_or_default();
    #[cfg(not(target_os = "macos"))]
    if t.is_empty() {
        if let Some(t) = migrate::electron_token(dir) {
            let _ = write_private(&dir.join("token"), t.as_bytes());
            return t;
        }
    }
    t
}

// Значение параметра так же, как String(v) в JS.
pub fn param(v: &Value) -> Option<String> {
    match v {
        Value::Null => None,
        Value::String(s) if s.is_empty() => None,
        Value::String(s) => Some(s.clone()),
        other => Some(other.to_string()),
    }
}

pub async fn call_api(y: &Yoru, path: &str, params: &Map<String, Value>, auth: bool) -> Result<Value, String> {
    // Serializer не Send: собираем строку запроса до первого await.
    let qs = {
        let mut q = url::form_urlencoded::Serializer::new(String::new());
        for (k, v) in params { if let Some(s) = param(v) { q.append_pair(k, &s); } }
        if auth {
            let t = y.token.lock().unwrap().clone();
            if t.is_empty() { return Err("Войдите в аккаунт Anime 365".into()); }
            q.append_pair("access_token", &t);
        }
        q.finish()
    };
    let mut u = format!("{BASE}/api/{path}");
    if !qs.is_empty() { u.push(if path.contains('?') { '&' } else { '?' }); u.push_str(&qs); }
    let res = y.http.get(&u).header("Cache-Control", "no-store").timeout(Duration::from_secs(60)).send().await
        .map_err(|_| "Не удалось подключиться к Anime 365. Проверьте интернет и повторите.".to_string())?;
    let j: Value = res.json().await.map_err(|_| "Сайт вернул неожиданный ответ. Повторите позже.".to_string())?;
    if let Some(e) = j.get("error").filter(|e| !e.is_null()) {
        return Err(e.get("message").and_then(Value::as_str).unwrap_or("Ошибка Anime 365").to_string());
    }
    j.get("data").cloned().ok_or_else(|| "Пустой ответ Anime 365".to_string())
}

#[tauri::command]
async fn api(y: State<'_, Yoru>, path: String, params: Map<String, Value>, auth: bool) -> Result<Value, String> {
    call_api(&y, &path, &params, auth).await
}

#[tauri::command]
async fn login(y: State<'_, Yoru>, email: String, password: String) -> Result<bool, String> {
    let mut p = Map::new();
    p.insert("email".into(), email.into());
    p.insert("password".into(), password.into());
    p.insert("app".into(), "universal".into());
    let d = call_api(&y, "login", &p, false).await?;
    let t = d.get("access_token").and_then(Value::as_str).filter(|t| !t.is_empty())
        .ok_or("Не удалось выполнить вход")?.to_string();
    y.save_token(&t);
    *y.token.lock().unwrap() = t;
    Ok(true)
}

#[tauri::command]
fn logout(y: State<'_, Yoru>) -> bool { y.token.lock().unwrap().clear(); y.save_token(""); true }

#[tauri::command]
fn signed_in(y: State<'_, Yoru>) -> bool { !y.token.lock().unwrap().is_empty() }

// Текст по ссылке сайта: субтитры .ass и страница каталога (для сезонов).
#[tauri::command]
async fn text(y: State<'_, Yoru>, url: String) -> Result<String, String> {
    let u = url::Url::parse(BASE).unwrap().join(&url).map_err(|_| "Неверная ссылка")?;
    if u.scheme() != "https" && u.scheme() != "http" { return Err("Неверная ссылка".into()); }
    let res = y.http.get(u).timeout(Duration::from_secs(60)).send().await.map_err(|e| e.to_string())?;
    if !res.status().is_success() { return Err(format!("HTTP {}", res.status().as_u16())); }
    res.text().await.map_err(|e| e.to_string())
}

// Скорость видеосервера: первые 4 МБ одного и того же файла (как в Android- и iOS-версиях).
#[tauri::command]
async fn server_speed(y: State<'_, Yoru>, url: String) -> Result<Value, String> {
    let ok = url::Url::parse(&url).ok().filter(|u| u.scheme() == "https" && u.host_str().is_some_and(|h| h.starts_with("ru-") && h.contains('.')));
    let Some(u) = ok else { return Ok(json!({ "error": "недоступен" })) };
    let start = Instant::now();
    let run = async {
        let res = y.http.get(u).header("Range", "bytes=0-4194303").header("Cache-Control", "no-store").send().await.ok()?;
        let status = res.status();
        if !status.is_success() { return Some(json!({ "error": format!("не отдал файл ({})", status.as_u16()) })); }
        let size = res.bytes().await.ok()?.len();
        if size <= 100_000 { return Some(json!({ "error": format!("не отдал файл ({})", status.as_u16()) })); }
        Some(json!({ "mbit": size as f64 * 8.0 / 1e6 / start.elapsed().as_secs_f64().max(0.001) }))
    };
    Ok(match tokio::time::timeout(Duration::from_secs(15), run).await.ok() {
        None => json!({ "error": "слишком медленно" }),
        Some(None) => json!({ "error": "недоступен" }),
        Some(Some(v)) => v,
    })
}

#[cfg(target_os = "macos")]
fn open_url(u: &str) { let _ = Command::new("/usr/bin/open").arg(u).spawn(); }
#[cfg(windows)]
fn open_url(u: &str) { let _ = Command::new("explorer").arg(u).spawn(); }
#[cfg(not(any(target_os = "macos", windows)))]
fn open_url(u: &str) { let _ = Command::new("xdg-open").arg(u).spawn(); }

#[tauri::command]
fn open_external(url: String) { if url.starts_with("https://") { open_url(&url); } }

// Показать скачанный файл в Finder / Проводнике / файловом менеджере.
#[tauri::command]
fn show_file(file: String) {
    #[cfg(target_os = "macos")]
    let _ = Command::new("/usr/bin/open").arg("-R").arg(&file).spawn();
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        let _ = Command::new("explorer").raw_arg(format!("/select,\"{file}\"")).spawn();
    }
    #[cfg(not(any(target_os = "macos", windows)))]
    if let Some(dir) = Path::new(&file).parent() { let _ = Command::new("xdg-open").arg(dir).spawn(); }
}

#[tauri::command]
fn version(app: AppHandle) -> String { app.package_info().version.to_string() }

static FULL: AtomicBool = AtomicBool::new(false);

#[tauri::command]
fn fullscreen(win: WebviewWindow, on: Option<bool>) -> bool {
    let now = win.is_fullscreen().unwrap_or(false);
    let _ = win.set_fullscreen(on.unwrap_or(!now));
    on.unwrap_or(!now)
}

// Скачивание серии в «Загрузки/Yoru Anime» (компьютеры без батареи), прогресс в интерфейс не чаще раза в секунду.
#[tauri::command]
fn download(app: AppHandle, y: State<'_, Yoru>, url: String, name: String) {
    let http = y.http.clone();
    let clean: String = name.chars().map(|c| if "\\/:*?\"<>|".contains(c) { ' ' } else { c }).collect();
    let Ok(dir) = app.path().download_dir().map(|d| d.join("Yoru Anime")) else { return };
    let file = dir.join(clean.trim());
    let fname = file.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    tauri::async_runtime::spawn(async move {
        let send = |v: Value| { let _ = app.emit("downloadProgress", v); };
        let result: Result<(), String> = async {
            fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
            let mut res = http.get(&url).send().await.map_err(|e| e.to_string())?;
            if !res.status().is_success() { return Err(format!("HTTP {}", res.status())); }
            let total = res.content_length().unwrap_or(0);
            let mut out = std::io::BufWriter::with_capacity(1 << 20, fs::File::create(&file).map_err(|e| e.to_string())?);
            let (mut got, mut last) = (0u64, Instant::now());
            while let Some(chunk) = res.chunk().await.map_err(|e| e.to_string())? {
                out.write_all(&chunk).map_err(|e| e.to_string())?;
                got += chunk.len() as u64;
                if last.elapsed() >= Duration::from_secs(1) {
                    last = Instant::now();
                    send(json!({ "id": url, "name": fname, "received": got, "total": total }));
                }
            }
            out.flush().map_err(|e| e.to_string())
        }.await;
        let state = if result.is_ok() { "completed" } else { "interrupted" };
        send(json!({ "id": url, "name": fname, "state": state, "file": file.to_string_lossy() }));
    });
}

// ---------- Прогресс и настройки ----------
// Интерфейс хранит их в localStorage и копирует в yoru-data.json (как 2.0.15). При первом запуске после
// Electron-версии этот файл переносится в localStorage до загрузки интерфейса, один раз.
const IMPORTED: &str = "yoru-data.imported";

#[tauri::command]
async fn save_data(app: AppHandle, y: State<'_, Yoru>, json: String, last: Option<bool>) -> Result<(), String> {
    if !json.is_empty() && json.len() <= 20_000_000 {
        let _ = fs::create_dir_all(&y.dir);
        let _ = write_private(&y.dir.join("yoru-data.json"), json.as_bytes());
        let _ = fs::write(y.dir.join(IMPORTED), b"");
    }
    if last == Some(true) { app.exit(0); }
    Ok(())
}

fn import_script(dir: &Path) -> Option<String> {
    if dir.join(IMPORTED).exists() { return None; }
    let j: Value = serde_json::from_slice(&fs::read(dir.join("yoru-data.json")).ok()?).ok()?;
    let data = serde_json::to_string(j.get("data")?.as_object()?).ok()?;
    Some(format!("(function(){{try{{if(window.top!==window||localStorage.getItem('yoru-imported'))return;var d={data};for(var k in d)if(localStorage.getItem(k)===null)localStorage.setItem(k,d[k]);localStorage.setItem('yoru-imported','1')}}catch(e){{}}}})();"))
}

// Перед выходом интерфейс сбрасывает данные в файл; не ответил за 1.5 с — выходим всё равно.
static CLOSING: AtomicBool = AtomicBool::new(false);
fn flush_and_exit(app: &AppHandle) {
    match app.get_webview_window("main") {
        Some(w) => { let _ = w.eval("window.__yoruFlush ? window.__yoruFlush() : window.__TAURI__.core.invoke('save_data', { json: '', last: true })"); }
        None => app.exit(0),
    }
    let app = app.clone();
    std::thread::spawn(move || { std::thread::sleep(Duration::from_millis(1500)); app.exit(0); });
}
pub fn quit_soon(app: AppHandle) {
    CLOSING.store(true, Ordering::SeqCst);
    std::thread::spawn(move || { std::thread::sleep(Duration::from_millis(300)); app.exit(0); });
}

// Меню Mac на русском. «Завершить» (Cmd+Q) — своё: стандартный пункт закрывает приложение сразу,
// не давая сохранить прогресс и настройки.
#[cfg(target_os = "macos")]
fn mac_menu(app: &AppHandle) -> tauri::Result<tauri::menu::Menu<tauri::Wry>> {
    use tauri::menu::{AboutMetadata, Menu, MenuItem, PredefinedMenuItem as P, Submenu};
    let quit = MenuItem::with_id(app, "quit", "Завершить Yoru Anime", true, Some("CmdOrCtrl+Q"))?;
    let about = AboutMetadata { name: Some("Yoru Anime".into()), version: Some(app.package_info().version.to_string()), ..Default::default() };
    Menu::with_items(app, &[
        &Submenu::with_items(app, "Yoru Anime", true, &[
            &P::about(app, Some("О Yoru Anime"), Some(about))?, &P::separator(app)?,
            &P::hide(app, Some("Скрыть Yoru Anime"))?, &P::hide_others(app, Some("Скрыть остальные"))?, &P::show_all(app, Some("Показать все"))?,
            &P::separator(app)?, &quit,
        ])?,
        &Submenu::with_items(app, "Правка", true, &[
            &P::undo(app, Some("Отменить"))?, &P::redo(app, Some("Повторить"))?, &P::separator(app)?,
            &P::cut(app, Some("Вырезать"))?, &P::copy(app, Some("Копировать"))?, &P::paste(app, Some("Вставить"))?, &P::select_all(app, Some("Выбрать всё"))?,
        ])?,
        &Submenu::with_items(app, "Окно", true, &[
            &P::minimize(app, Some("Свернуть"))?, &P::maximize(app, Some("Изменить масштаб"))?, &P::fullscreen(app, Some("Полный экран"))?,
            &P::separator(app)?, &P::close_window(app, Some("Закрыть окно"))?,
        ])?,
    ])
}

// Папка данных та же, что у Electron-версии («Yoru Anime» в папке настроек пользователя):
// так вход, загрузки и прогресс остаются на месте после обновления.
fn data_dir(app: &AppHandle) -> PathBuf {
    // Только для проверочных сборок: папку можно задать при сборке, чтобы не трогать настоящие данные.
    if let Some(d) = option_env!("YORU_TEST_DATA_DIR") { return d.into(); }
    app.path().config_dir().unwrap_or_else(|_| std::env::temp_dir()).join("Yoru Anime")
}

fn main() {
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            if let Some(w) = app.get_webview_window("main") { let _ = w.unminimize(); let _ = w.show(); let _ = w.set_focus(); }
        }))
        .register_asynchronous_uri_scheme_protocol("yoru", |ctx, req, responder| {
            let app = ctx.app_handle().clone();
            tauri::async_runtime::spawn_blocking(move || responder.respond(dl::serve(&app, &req)));
        })
        .setup(|app| {
            let handle = app.handle().clone();
            #[cfg(target_os = "macos")]
            {
                app.set_menu(mac_menu(&handle)?)?;
                app.on_menu_event(|app, e| if e.id() == "quit" && !CLOSING.swap(true, Ordering::SeqCst) { flush_and_exit(app); });
            }
            let dir = data_dir(&handle);
            let _ = fs::create_dir_all(&dir);
            let token = read_token(&dir);
            let http = reqwest::Client::builder().user_agent(UA).connect_timeout(Duration::from_secs(20)).read_timeout(Duration::from_secs(60)).build()?;
            app.manage(dl::Dl::new(dir.join("Downloads")));
            let import = import_script(&dir);
            app.manage(Yoru { token: Mutex::new(token), http, dir: dir.clone() });

            let mut b = WebviewWindowBuilder::new(app, "main", WebviewUrl::App("index.html".into()))
                .title("Yoru Anime")
                .inner_size(1360.0, 860.0)
                .min_inner_size(900.0, 600.0)
                .background_color(tauri::window::Color(10, 16, 28, 255))
                .user_agent(UA)
                .on_page_load(move |w, p| {
                    if p.event() != PageLoadEvent::Finished { return; }
                    let app = w.app_handle();
                    let dir = &app.state::<Yoru>().dir;
                    if !dir.join(IMPORTED).exists() { let _ = fs::write(dir.join(IMPORTED), b""); }
                    dl::start(app);
                });
            #[cfg(target_os = "macos")]
            { b = b.title_bar_style(tauri::TitleBarStyle::Overlay).hidden_title(true); }
            if let Some(js) = import { b = b.initialization_script(&js); }
            let win = b.build()?;
            let w = win.clone();
            win.on_window_event(move |e| match e {
                // Полноэкранный режим меняется и кнопкой окна: сообщаем интерфейсу о каждом переходе.
                WindowEvent::Resized(_) => {
                    let fs = w.is_fullscreen().unwrap_or(false);
                    if FULL.swap(fs, Ordering::Relaxed) != fs { let _ = w.emit("fullscreenChanged", fs); }
                }
                WindowEvent::CloseRequested { api, .. } if !CLOSING.swap(true, Ordering::SeqCst) => {
                    api.prevent_close();
                    flush_and_exit(w.app_handle());
                }
                _ => {}
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            api, login, logout, signed_in, text, server_speed, open_external, show_file, version, fullscreen, download, save_data,
            update::check_update, update::install_update,
            dl::has_battery, dl::dl_list, dl::dl_enqueue, dl::dl_retry, dl::dl_remove, dl::dl_text, dl::dl_space
        ])
        .build(tauri::generate_context!())
        .expect("не удалось запустить Yoru Anime");
    app.run(|app, e| {
        // Cmd+Q и выход из меню тоже сначала сохраняют данные.
        if let RunEvent::ExitRequested { code: None, api, .. } = e {
            if !CLOSING.swap(true, Ordering::SeqCst) { api.prevent_exit(); flush_and_exit(app); }
        }
    });
}
