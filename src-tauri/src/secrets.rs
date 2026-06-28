use keyring::{Entry, Error, Result};

const SERVICE: &str = "com.murmur.app";

pub fn set(account: &str, value: &str) -> Result<()> {
    Entry::new(SERVICE, account)?.set_password(value)
}

pub fn get(account: &str) -> Result<Option<String>> {
    match Entry::new(SERVICE, account)?.get_password() {
        Ok(s) => Ok(Some(s)),
        Err(Error::NoEntry) => Ok(None),
        Err(e) => Err(e),
    }
}

pub fn delete(account: &str) -> Result<()> {
    match Entry::new(SERVICE, account)?.delete_credential() {
        Ok(()) | Err(Error::NoEntry) => Ok(()),
        Err(e) => Err(e),
    }
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
