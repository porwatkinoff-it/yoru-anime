// Вход из Electron-версии 2.0.x на Windows и Linux: там токен лежит в token.bin, зашифрованный safeStorage.
// Расшифровываем его один раз и дальше храним, как на Mac, в файле token, доступном только этому пользователю.
use std::{fs, path::Path};

pub fn electron_token(dir: &Path) -> Option<String> {
    let b = fs::read(dir.join("token.bin")).ok()?;
    let plain = if b.starts_with(b"v10") || b.starts_with(b"v11") { decrypt(dir, &b)? } else { b };
    let t = String::from_utf8(plain).ok()?.trim().to_string();
    (!t.is_empty() && t.chars().all(|c| c.is_ascii_graphic())).then_some(t)
}

// Windows: ключ AES-256-GCM лежит в «Local State», сам он защищён DPAPI текущего пользователя.
#[cfg(windows)]
fn decrypt(dir: &Path, b: &[u8]) -> Option<Vec<u8>> {
    use aes_gcm::{aead::Aead, Aes256Gcm, KeyInit, Nonce};
    use base64::Engine;
    if !b.starts_with(b"v10") || b.len() < 3 + 12 + 16 { return None; }
    let state: serde_json::Value = serde_json::from_slice(&fs::read(dir.join("Local State")).ok()?).ok()?;
    let key = base64::engine::general_purpose::STANDARD.decode(state["os_crypt"]["encrypted_key"].as_str()?).ok()?;
    let key = dpapi(key.strip_prefix(b"DPAPI")?)?;
    let (nonce, data) = b[3..].split_at(12);
    Aes256Gcm::new_from_slice(&key).ok()?.decrypt(Nonce::from_slice(nonce), data).ok()
}

#[cfg(windows)]
fn dpapi(data: &[u8]) -> Option<Vec<u8>> {
    use windows_sys::Win32::{Foundation::LocalFree, Security::Cryptography::{CryptUnprotectData, CRYPT_INTEGER_BLOB}};
    let input = CRYPT_INTEGER_BLOB { cbData: data.len() as u32, pbData: data.as_ptr() as *mut u8 };
    let mut out = CRYPT_INTEGER_BLOB { cbData: 0, pbData: std::ptr::null_mut() };
    let ok = unsafe { CryptUnprotectData(&input, std::ptr::null_mut(), std::ptr::null(), std::ptr::null(), std::ptr::null(), 0, &mut out) };
    if ok == 0 || out.pbData.is_null() { return None; }
    let v = unsafe { std::slice::from_raw_parts(out.pbData, out.cbData as usize) }.to_vec();
    unsafe { LocalFree(out.pbData as _) };
    Some(v)
}

// Linux: «v10» — без связки ключей, ключ из «peanuts» (PBKDF2-SHA1, соль saltysalt, 1 проход).
// «v11» зашифрован ключом из связки ключей GNOME/KDE — его не трогаем, войти нужно один раз заново.
#[cfg(not(windows))]
fn decrypt(_dir: &Path, b: &[u8]) -> Option<Vec<u8>> {
    use aes::cipher::{block_padding::Pkcs7, BlockDecryptMut, KeyIvInit};
    const KEY: [u8; 16] = [253, 98, 31, 229, 162, 180, 2, 83, 157, 250, 20, 124, 169, 39, 39, 120];
    if !b.starts_with(b"v10") { return None; }
    cbc::Decryptor::<aes::Aes128>::new(&KEY.into(), &[b' '; 16].into()).decrypt_padded_vec_mut::<Pkcs7>(&b[3..]).ok()
}
