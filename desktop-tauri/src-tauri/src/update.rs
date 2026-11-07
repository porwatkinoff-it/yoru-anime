// Обновления из GitHub Releases — те же файлы и та же замена, что у Electron-версии 2.0.x,
// поэтому 2.0.15 обновляется до этой версии, а эта — до следующих.
use crate::{Yoru, UA};
use serde_json::{json, Value};
use std::{fs, io::Write, path::PathBuf, process::Command, time::Duration};
use tauri::{AppHandle, Emitter, State};

const REPO: &str = "porwatkinoff-it/yoru-anime";

fn numeric(v: &str) -> Vec<u64> { v.trim_start_matches('v').split('.').map(|n| n.trim().parse().unwrap_or(0)).collect() }
fn newer(a: &str, b: &str) -> bool {
    let (x, y) = (numeric(a), numeric(b));
    for i in 0..x.len().max(y.len()) {
        let (p, q) = (x.get(i).copied().unwrap_or(0), y.get(i).copied().unwrap_or(0));
        if p != q { return p > q; }
    }
    false
}

// Intel-сборка на Apple Silicon работает через Rosetta: такой Mac переводим на родную сборку.
#[cfg(target_os = "macos")]
fn rosetta() -> bool {
    let mut v: libc::c_int = 0;
    let mut size = std::mem::size_of::<libc::c_int>();
    let ok = unsafe { libc::sysctlbyname(c"sysctl.proc_translated".as_ptr(), &mut v as *mut _ as *mut libc::c_void, &mut size, std::ptr::null_mut(), 0) };
    ok == 0 && v == 1
}
#[cfg(not(target_os = "macos"))]
fn rosetta() -> bool { false }

fn asset_for(assets: &[Value]) -> Option<&Value> {
    let arch = if cfg!(target_arch = "aarch64") || rosetta() { "arm64" } else { "x64" };
    let find = |ok: &dyn Fn(&str) -> bool| assets.iter().find(|a| a["name"].as_str().is_some_and(ok));
    if cfg!(target_os = "macos") { return find(&|n| n.ends_with(&format!("-mac-{arch}.zip"))); }
    if cfg!(windows) { return find(&|n| n.ends_with(&format!("-win-{arch}-setup.exe"))).or_else(|| find(&|n| n.contains("-win-") && n.ends_with("setup.exe"))); }
    // На Linux сами обновляем только AppImage: .deb ставится менеджером пакетов.
    std::env::var_os("APPIMAGE")?;
    let a = if arch == "x64" { "x86_64" } else { "arm64" };
    find(&|n| n.ends_with(&format!("-linux-{a}.AppImage")))
}

#[tauri::command]
pub async fn check_update(app: AppHandle, y: State<'_, Yoru>) -> Result<Value, String> {
    let res = y.http.get(format!("https://api.github.com/repos/{REPO}/releases/latest"))
        .header("Accept", "application/vnd.github+json").header("User-Agent", UA)
        .timeout(Duration::from_secs(30)).send().await.map_err(|_| "GitHub не ответил".to_string())?;
    if !res.status().is_success() { return Err(format!("GitHub не ответил ({})", res.status().as_u16())); }
    let r: Value = res.json().await.map_err(|e| e.to_string())?;
    let version = r["tag_name"].as_str().unwrap_or("").trim_start_matches('v').to_string();
    let current = app.package_info().version.to_string();
    let assets = r["assets"].as_array().cloned().unwrap_or_default();
    let asset = asset_for(&assets);
    let native = cfg!(target_os = "macos") && rosetta() && asset.is_some();
    let available = newer(&version, &current) || native;
    Ok(json!({
        "version": version, "current": current, "available": available, "toArm": native && !newer(&version, &current),
        "notes": r["body"].as_str().unwrap_or(""), "page": r["html_url"].as_str().unwrap_or(""),
        "asset": asset.map(|a| json!({ "name": a["name"], "url": a["browser_download_url"], "size": a["size"] })),
        "auto": asset.is_some() && !cfg!(debug_assertions)
    }))
}

#[cfg(unix)]
fn detached(cmd: &mut Command) -> &mut Command {
    use std::os::unix::process::CommandExt;
    cmd.process_group(0).stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null())
}

#[tauri::command]
pub async fn install_update(app: AppHandle, y: State<'_, Yoru>, url: String, name: String) -> Result<bool, String> {
    // Скачиваем только файлы релизов этого приложения.
    if !url.starts_with(&format!("https://github.com/{REPO}/releases/download/")) { return Err("Неверная ссылка на обновление".into()); }
    let name = std::path::Path::new(&name).file_name().ok_or("Неверное имя файла")?.to_owned();
    let tmp: PathBuf = std::env::temp_dir().join(format!("yoru-update-{}", std::process::id()));
    let _ = fs::remove_dir_all(&tmp);
    fs::create_dir_all(&tmp).map_err(|e| e.to_string())?;
    let file = tmp.join(&name);
    let mut res = y.http.get(&url).send().await.map_err(|_| "Нет сети".to_string())?;
    if !res.status().is_success() { return Err(format!("HTTP {}", res.status().as_u16())); }
    let total = res.content_length().unwrap_or(0);
    {
        let mut out = std::io::BufWriter::with_capacity(1 << 20, fs::File::create(&file).map_err(|e| e.to_string())?);
        let (mut done, mut last) = (0u64, 0u64);
        while let Some(c) = res.chunk().await.map_err(|_| "Загрузка прервалась".to_string())? {
            out.write_all(&c).map_err(|e| e.to_string())?;
            done += c.len() as u64;
            if done - last > 1 << 20 { last = done; let _ = app.emit("updateProgress", json!([done, total])); }
        }
        out.flush().map_err(|e| e.to_string())?;
        if total > 0 && done < total { return Err("Загрузка прервалась".into()); }
    }
    let pid = std::process::id().to_string();
    #[cfg(target_os = "macos")]
    {
        // Приложение заменяется целиком после выхода; файл скачан самим приложением, поэтому без карантина.
        let exe = std::env::current_exe().map_err(|e| e.to_string())?;
        let bundle = exe.ancestors().nth(3).ok_or("Не найдено приложение")?.to_path_buf();
        if bundle.extension().is_none_or(|e| e != "app") { return Err("Не найдено приложение".into()); }
        let unpack = tmp.join("app");
        let ok = Command::new("/usr/bin/ditto").args(["-x", "-k"]).arg(&file).arg(&unpack).status().is_ok_and(|s| s.success());
        if !ok { return Err("Не удалось распаковать обновление".into()); }
        let fresh = fs::read_dir(&unpack).map_err(|e| e.to_string())?.flatten().map(|e| e.path()).find(|p| p.extension().is_some_and(|e| e == "app")).ok_or("В архиве нет приложения")?;
        let script = r#"while kill -0 "$1" 2>/dev/null; do sleep 0.3; done; rm -rf "$2" && mv "$3" "$2"; open "$2"; rm -rf "$4""#;
        detached(Command::new("/bin/sh").args(["-c", script, "sh", &pid]).arg(&bundle).arg(&fresh).arg(&tmp)).spawn().map_err(|e| e.to_string())?;
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        // --force-run: установщик сам запустит новую версию (см. windows/hooks.nsh).
        Command::new(&file).args(["/S", "--force-run"]).creation_flags(0x0000_0008 | 0x0000_0200).spawn().map_err(|e| e.to_string())?;
    }
    #[cfg(not(any(target_os = "macos", windows)))]
    {
        use std::os::unix::fs::PermissionsExt;
        let target = std::env::var_os("APPIMAGE").ok_or("Обновляется только AppImage")?;
        fs::set_permissions(&file, fs::Permissions::from_mode(0o755)).map_err(|e| e.to_string())?;
        let script = r#"while kill -0 "$1" 2>/dev/null; do sleep 0.3; done; mv -f "$2" "$3" && "$3" & "#;
        detached(Command::new("/bin/sh").args(["-c", script, "sh", &pid]).arg(&file).arg(&target)).spawn().map_err(|e| e.to_string())?;
    }
    crate::quit_soon(app);
    Ok(true)
}
