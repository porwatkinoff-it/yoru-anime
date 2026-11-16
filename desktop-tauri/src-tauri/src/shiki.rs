// Шикимори: вход через OAuth в отдельном окне сайта и запросы к API от имени пользователя.
// Ключи приложения (Client ID и Secret) пользователь вводит один раз — в публичный репозиторий они не попадают.
// Ключи и токены лежат в shikimori.json в папке данных (права только у пользователя) и в страницу не отдаются.
use crate::{write_private, Yoru};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    fs,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tauri::{webview::NewWindowResponse, AppHandle, Manager, State, WebviewUrl, WebviewWindowBuilder, WindowEvent};
use tokio::sync::oneshot;

const SITE: &str = "https://shikimori.io";
const REDIRECT: &str = "yoru://shikimori";
#[cfg(target_os = "macos")]
const AGENT: &str = "Yoru/2.3 (macOS)";
#[cfg(windows)]
const AGENT: &str = "Yoru/2.3 (Windows)";
#[cfg(not(any(target_os = "macos", windows)))]
const AGENT: &str = "Yoru/2.3 (Linux)";

pub struct Shiki {
    file: PathBuf,
    data: Mutex<Value>, // {app: {id, secret}, oauth: {access_token, refresh_token, expires_at}, user: {id, nickname}}
}

impl Shiki {
    pub fn new(dir: &Path) -> Self {
        let file = dir.join("shikimori.json");
        let data = fs::read(&file).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_else(|| json!({}));
        Shiki { file, data: Mutex::new(data) }
    }
    // Меняет данные и сразу пишет файл; блокировка не переживает await.
    fn update(&self, f: impl FnOnce(&mut Value)) {
        let v = { let mut d = self.data.lock().unwrap(); f(&mut d); d.clone() };
        let _ = write_private(&self.file, v.to_string().as_bytes());
    }
    // Вход для аккаунта Yoru (общий формат с iPhone и Android): ключи приложения и токены, шифруются паролем Yoru.
    pub fn vault_payload(&self) -> Option<Value> {
        let d = self.data.lock().unwrap();
        let access = d["oauth"]["access_token"].as_str().unwrap_or("");
        let uid = d["user"]["id"].as_i64().unwrap_or(0);
        if access.is_empty() || uid <= 0 { return None; }
        Some(json!({
            "id": d["app"]["id"], "secret": d["app"]["secret"], "access": access,
            "refresh": d["oauth"]["refresh_token"].as_str().unwrap_or(""),
            "expires": (d["oauth"]["expires_at"].as_f64().unwrap_or(0.0) * 1000.0) as i64,
            "userId": uid, "nickname": d["user"]["nickname"].as_str().unwrap_or("")
        }))
    }
    // Вход пришёл из аккаунта Yoru; None — «Выйти везде» на другом устройстве.
    pub fn install(&self, v: Option<&Value>) {
        self.update(|d| {
            if !d.is_object() { *d = json!({}); }
            let m = d.as_object_mut().unwrap();
            let Some(o) = v else { m.remove("oauth"); m.remove("user"); return };
            let (id, secret) = (o["id"].as_str().unwrap_or(""), o["secret"].as_str().unwrap_or(""));
            if !id.is_empty() && !secret.is_empty() { m.insert("app".into(), json!({ "id": id, "secret": secret })); }
            let access = o["access"].as_str().unwrap_or("");
            if access.is_empty() { return; }
            m.insert("oauth".into(), json!({ "access_token": access, "refresh_token": o["refresh"].as_str().unwrap_or(""), "expires_at": o["expires"].as_f64().unwrap_or(0.0) / 1000.0 }));
            m.insert("user".into(), json!({ "id": o["userId"].as_i64().unwrap_or(0), "nickname": o["nickname"].as_str().unwrap_or("") }));
        });
    }
    fn get(&self, a: &str, b: &str) -> String { self.data.lock().unwrap()[a][b].as_str().unwrap_or("").to_string() }
    fn keys(&self) -> (String, String) { (self.get("app", "id"), self.get("app", "secret")) }
}

fn now() -> f64 { SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0) }

fn status_of(s: &Shiki) -> Value {
    let d = s.data.lock().unwrap();
    let (id, secret) = (d["app"]["id"].as_str().unwrap_or(""), d["app"]["secret"].as_str().unwrap_or(""));
    json!({
        "configured": !id.is_empty() && !secret.is_empty(),
        "signedIn": d["oauth"]["access_token"].is_string() && d["user"]["id"].as_i64().unwrap_or(0) > 0,
        "userId": d["user"]["id"].as_i64().unwrap_or(0),
        "nickname": d["user"]["nickname"].as_str().unwrap_or("")
    })
}

#[tauri::command]
pub fn shiki_status(s: State<'_, Shiki>) -> Value { status_of(&s) }

#[tauri::command]
pub fn shiki_set_keys(s: State<'_, Shiki>, id: String, secret: String) -> Result<Value, String> {
    let (id, secret) = (id.trim().to_string(), secret.trim().to_string());
    if id.is_empty() || secret.is_empty() || !(id.clone() + &secret).chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_') {
        return Err("Ключи должны состоять из латиницы, цифр, - и _".into());
    }
    s.update(|d| d["app"] = json!({ "id": id, "secret": secret }));
    Ok(status_of(&s))
}

#[tauri::command]
pub fn shiki_logout(s: State<'_, Shiki>) -> Value {
    s.update(|d| if let Some(o) = d.as_object_mut() { o.remove("oauth"); o.remove("user"); });
    status_of(&s)
}

// Обмен кода или refresh-токена на новые токены.
async fn token(y: &Yoru, s: &Shiki, form: &[(&str, &str)]) -> Result<(), String> {
    let (id, secret) = s.keys();
    if id.is_empty() || secret.is_empty() { return Err("Сначала введите ключи приложения Шикимори".into()); }
    let body = {
        let mut ser = url::form_urlencoded::Serializer::new(String::new());
        for (k, v) in form { ser.append_pair(k, v); }
        ser.append_pair("client_id", &id).append_pair("client_secret", &secret);
        ser.finish()
    };
    let res = y.http.post(format!("{SITE}/oauth/token")).header("User-Agent", AGENT)
        .header("Content-Type", "application/x-www-form-urlencoded").body(body)
        .timeout(Duration::from_secs(20)).send().await.map_err(|e| e.to_string())?;
    let code = res.status().as_u16();
    let mut o: Value = res.json().await.unwrap_or(Value::Null);
    if code != 200 || !o["access_token"].is_string() {
        let refresh = form.iter().any(|(k, v)| *k == "grant_type" && *v == "refresh_token");
        if refresh && (code == 400 || code == 401) {
            // Токены Шикимори одноразовые: если их уже обновило другое устройство, свежие лежат в аккаунте Yoru.
            let old = s.get("oauth", "refresh_token");
            if crate::account::recover("shikimori").await && s.get("oauth", "refresh_token") != old { return Ok(()); }
            s.update(|d| if let Some(m) = d.as_object_mut() { m.remove("oauth"); m.remove("user"); });
            return Err("Вход в Шикимори истёк — войдите снова".into());
        }
        return Err(if code == 401 { "Шикимори не принял ключи приложения — проверьте Client ID и Secret".into() } else { format!("Шикимори не пустил ({code})") });
    }
    o["expires_at"] = json!(now() + o["expires_in"].as_f64().unwrap_or(86400.0) - 60.0);
    s.update(|d| d["oauth"] = o);
    crate::account::vault_changed("shikimori");
    Ok(())
}

async fn call(y: &Yoru, s: &Shiki, method: &str, path: &str, body: Option<&Value>) -> Result<Value, String> {
    let (exp, refresh) = { let d = s.data.lock().unwrap(); (d["oauth"]["expires_at"].as_f64().unwrap_or(0.0), d["oauth"]["refresh_token"].as_str().unwrap_or("").to_string()) };
    if exp < now() && !refresh.is_empty() { token(y, s, &[("grant_type", "refresh_token"), ("refresh_token", &refresh)]).await?; }
    let access = s.get("oauth", "access_token");
    if access.is_empty() { return Err("Войдите в Шикимори".into()); }
    if !path.starts_with("/api/") { return Err("Неверный адрес".into()); }
    let m = reqwest::Method::from_bytes(method.as_bytes()).map_err(|_| "Неверный запрос")?;
    for attempt in 0..3u64 {
        let mut r = y.http.request(m.clone(), format!("{SITE}{path}")).header("User-Agent", AGENT)
            .header("Authorization", format!("Bearer {access}")).timeout(Duration::from_secs(20));
        if let Some(b) = body { r = r.json(b); }
        let res = r.send().await.map_err(|e| e.to_string())?;
        let code = res.status().as_u16();
        if code == 429 && attempt < 2 { tokio::time::sleep(Duration::from_millis(800 * (attempt + 1))).await; continue; }
        if code == 401 {
            s.update(|d| d["oauth"]["expires_at"] = json!(0));
            return Err("Шикимори попросил войти заново".into());
        }
        if !(200..300).contains(&code) { return Err(format!("Шикимори ответил ошибкой {code}")); }
        let text = res.text().await.map_err(|e| e.to_string())?;
        return Ok(if text.trim().is_empty() { json!({}) } else { serde_json::from_str(&text).map_err(|e| e.to_string())? });
    }
    Err("Шикимори занят — попробуйте позже".into())
}

#[tauri::command]
pub async fn shiki_call(y: State<'_, Yoru>, s: State<'_, Shiki>, method: String, path: String, body: Option<Value>) -> Result<Value, String> {
    call(&y, &s, &method, &path, body.as_ref()).await
}

// Окно входа: страница авторизации Шикимори. Когда сайт уходит на yoru://shikimori?code=…, окно закрывается,
// код меняется на токены, а приложение узнаёт ник пользователя.
#[tauri::command]
pub async fn shiki_login(app: AppHandle, y: State<'_, Yoru>, s: State<'_, Shiki>) -> Result<Value, String> {
    let (id, secret) = s.keys();
    if id.is_empty() || secret.is_empty() { return Err("Сначала введите ключи приложения Шикимори".into()); }
    let mut url = url::Url::parse(&format!("{SITE}/oauth/authorize")).unwrap();
    url.query_pairs_mut().append_pair("client_id", &id).append_pair("redirect_uri", REDIRECT)
        .append_pair("response_type", "code").append_pair("scope", "user_rates");
    if let Some(w) = app.get_webview_window("shiki-login") { let _ = w.destroy(); }
    let (tx, rx) = oneshot::channel::<Option<String>>();
    let tx = Arc::new(Mutex::new(Some(tx)));
    let (t1, t2, h) = (tx.clone(), tx.clone(), app.clone());
    let w = WebviewWindowBuilder::new(&app, "shiki-login", WebviewUrl::External(url))
        .title("Вход в Шикимори").inner_size(560.0, 760.0).center()
        .on_navigation(move |u| {
            if !u.as_str().starts_with(REDIRECT) { return true; }
            let q: HashMap<String, String> = u.query_pairs().into_owned().collect();
            if let Some(t) = t1.lock().unwrap().take() { let _ = t.send(q.get("code").cloned()); }
            false
        })
        .on_new_window(move |u, _| {
            let h = h.clone();
            tauri::async_runtime::spawn(async move { if let Some(w) = h.get_webview_window("shiki-login") { let _ = w.navigate(u); } });
            NewWindowResponse::Deny
        })
        .build().map_err(|e| e.to_string())?;
    w.on_window_event(move |e| if let WindowEvent::Destroyed = e { if let Some(t) = t2.lock().unwrap().take() { let _ = t.send(None); } });
    let code = rx.await.ok().flatten();
    let _ = w.destroy();
    let code = code.ok_or("Вход отменён")?;
    token(&y, &s, &[("grant_type", "authorization_code"), ("code", &code), ("redirect_uri", REDIRECT)]).await?;
    let me = call(&y, &s, "GET", "/api/users/whoami", None).await?;
    let uid = me["id"].as_i64().filter(|i| *i > 0).ok_or("Не удалось узнать пользователя Шикимори")?;
    s.update(|d| d["user"] = json!({ "id": uid, "nickname": me["nickname"].as_str().unwrap_or("") }));
    crate::account::vault_changed("shikimori");
    Ok(status_of(&s))
}
