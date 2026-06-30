use keyring::{Entry, Error, Result};
use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

const SERVICE: &str = "com.murmur.app";

// Process-lifetime cache of secret lookups. The onboarding UI polls key
// presence every ~1.5s; without this, each poll hits the macOS Keychain and —
// for an ad-hoc-signed build whose "Always Allow" grant doesn't persist —
// re-triggers the access prompt in an endless loop. Caching means we touch the
// Keychain at most once per account per launch (one prompt, then silent).
// A failed read (e.g. the user denies) is NOT cached, so it can be retried.
fn cache() -> &'static Mutex<HashMap<String, Option<String>>> {
    static CACHE: OnceLock<Mutex<HashMap<String, Option<String>>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

pub fn set(account: &str, value: &str) -> Result<()> {
    Entry::new(SERVICE, account)?.set_password(value)?;
    cache()
        .lock()
        .unwrap()
        .insert(account.to_owned(), Some(value.to_owned()));
    Ok(())
}

pub fn get(account: &str) -> Result<Option<String>> {
    if let Some(v) = cache().lock().unwrap().get(account) {
        return Ok(v.clone());
    }
    let v = match Entry::new(SERVICE, account)?.get_password() {
        Ok(s) => Some(s),
        Err(Error::NoEntry) => None,
        Err(e) => return Err(e),
    };
    cache().lock().unwrap().insert(account.to_owned(), v.clone());
    Ok(v)
}

pub fn delete(account: &str) -> Result<()> {
    let res = match Entry::new(SERVICE, account)?.delete_credential() {
        Ok(()) | Err(Error::NoEntry) => Ok(()),
        Err(e) => Err(e),
    };
    cache().lock().unwrap().insert(account.to_owned(), None);
    res
}

#[tauri::command]
pub fn secret_set(key: String, value: String) -> std::result::Result<(), String> {
    set(&key, &value).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn secret_get(key: String) -> std::result::Result<Option<String>, String> {
    get(&key).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn secret_delete(key: String) -> std::result::Result<(), String> {
    delete(&key).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn roundtrip_and_delete() {
        let acct = "test-byok-key";
        set(acct, "sk-secret-123").unwrap();
        assert_eq!(get(acct).unwrap().as_deref(), Some("sk-secret-123"));
        delete(acct).unwrap();
        assert_eq!(get(acct).unwrap(), None);
    }
}
