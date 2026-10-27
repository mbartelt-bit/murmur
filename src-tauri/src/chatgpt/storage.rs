//! Atomic manifest + bounded OS-keyring entries, including Windows' small blob limit.
use anyhow::{anyhow, bail, Context, Result};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

const SERVICE: &str = "com.murmur.app.chatgpt";
const MANIFEST: &str = "vault-manifest";
// keyring encodes Windows passwords as UTF-16: 1000 ASCII chars = 2000 bytes.
const CHUNK_BYTES: usize = 1000;
const MAX_CHUNKS: usize = 512;
#[derive(Deserialize, Serialize)]
struct Manifest {
    version: u8,
    generation: String,
    chunks: usize,
}
trait Store {
    fn get(&self, key: &str) -> Result<Option<String>>;
    fn set(&self, key: &str, value: &str) -> Result<()>;
    fn delete(&self, key: &str);
}
struct Keyring;
impl Store for Keyring {
    fn get(&self, key: &str) -> Result<Option<String>> {
        match keyring::Entry::new(SERVICE, key)?.get_password() {
            Ok(v) => Ok(Some(v)),
            Err(keyring::Error::NoEntry) => Ok(None),
            Err(_) => bail!("Unlock your system credential store to use ChatGPT"),
        }
    }
    fn set(&self, key: &str, value: &str) -> Result<()> {
        keyring::Entry::new(SERVICE, key)?
            .set_password(value)
            .map_err(|_| {
                anyhow!("Could not save ChatGPT credentials in your system credential store")
            })
    }
    fn delete(&self, key: &str) {
        if let Ok(entry) = keyring::Entry::new(SERVICE, key) {
            let _ = entry.delete_credential();
        }
    }
}
fn manifest(store: &impl Store) -> Result<Option<Manifest>> {
    let Some(value) = store.get(MANIFEST)? else {
        return Ok(None);
    };
    let m: Manifest =
        serde_json::from_str(&value).context("ChatGPT credential manifest is invalid")?;
    if m.version != 1
        || m.chunks == 0
        || m.chunks > MAX_CHUNKS
        || uuid::Uuid::parse_str(&m.generation).is_err()
    {
        bail!("ChatGPT credential manifest is invalid")
    }
    Ok(Some(m))
}
fn chunk_key(m: &Manifest, index: usize) -> String {
    format!("vault-{}-{index}", m.generation)
}
fn read_from(store: &impl Store) -> Result<Option<Zeroizing<String>>> {
    let Some(m) = manifest(store)? else {
        return Ok(None);
    };
    let mut encoded = Zeroizing::new(String::new());
    for i in 0..m.chunks {
        let chunk =
            Zeroizing::new(store.get(&chunk_key(&m, i))?.ok_or_else(|| {
                anyhow!("ChatGPT credential storage is incomplete; sign in again")
            })?);
        if chunk.len() > CHUNK_BYTES {
            bail!("ChatGPT credential entry is invalid")
        }
        encoded.push_str(&chunk);
    }
    let bytes = Zeroizing::new(
        STANDARD
            .decode(encoded.as_bytes())
            .context("ChatGPT credential storage is invalid")?,
    );
    Ok(Some(Zeroizing::new(
        String::from_utf8(bytes.to_vec()).context("ChatGPT credential storage is invalid")?,
    )))
}
fn write_to(store: &impl Store, value: &str) -> Result<()> {
    let previous = manifest(store)?;
    let encoded = Zeroizing::new(STANDARD.encode(value.as_bytes()));
    let chunks = encoded.len().div_ceil(CHUNK_BYTES);
    if chunks == 0 || chunks > MAX_CHUNKS {
        bail!("Too many ChatGPT accounts for the credential store")
    }
    let next = Manifest {
        version: 1,
        generation: uuid::Uuid::new_v4().to_string(),
        chunks,
    };
    let result = (|| -> Result<()> {
        for (i, chunk) in encoded.as_bytes().chunks(CHUNK_BYTES).enumerate() {
            // Base64 is ASCII, so every byte boundary is also a string boundary.
            store.set(&chunk_key(&next, i), std::str::from_utf8(chunk)?)?;
        }
        // The old generation remains readable until this single final entry commits.
        store.set(MANIFEST, &serde_json::to_string(&next)?)
    })();
    if result.is_err() {
        for i in 0..next.chunks {
            store.delete(&chunk_key(&next, i));
        }
        return result;
    }
    if let Some(previous) = previous {
        for i in 0..previous.chunks {
            store.delete(&chunk_key(&previous, i));
        }
    }
    Ok(())
}
pub(super) fn load() -> Result<Option<Zeroizing<String>>> {
    read_from(&Keyring)
}
pub(super) fn save(value: &str) -> Result<()> {
    write_to(&Keyring, value)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{cell::RefCell, collections::HashMap};
    #[derive(Default)]
    struct Memory {
        values: RefCell<HashMap<String, String>>,
        fail_commit: RefCell<bool>,
    }
    impl Store for Memory {
        fn get(&self, key: &str) -> Result<Option<String>> {
            Ok(self.values.borrow().get(key).cloned())
        }
        fn set(&self, key: &str, value: &str) -> Result<()> {
            if key == MANIFEST && *self.fail_commit.borrow() {
                bail!("simulated locked keyring")
            }
            assert!(value.len() <= CHUNK_BYTES);
            assert!(value.encode_utf16().count() * 2 <= 2560);
            self.values.borrow_mut().insert(key.into(), value.into());
            Ok(())
        }
        fn delete(&self, key: &str) {
            self.values.borrow_mut().remove(key);
        }
    }
    #[test]
    fn large_unicode_vault_roundtrips_bounded_keyring_entries() {
        let store = Memory::default();
        let value = "test-only token 東京 ".repeat(1000);
        write_to(&store, &value).unwrap();
        assert_eq!(read_from(&store).unwrap().unwrap().as_str(), value);
        write_to(&store, "replacement").unwrap();
        assert_eq!(read_from(&store).unwrap().unwrap().as_str(), "replacement");
        assert_eq!(store.values.borrow().len(), 2); // manifest + one live chunk
    }
    #[test]
    fn failed_commit_preserves_previous_generation() {
        let store = Memory::default();
        write_to(&store, "old").unwrap();
        *store.fail_commit.borrow_mut() = true;
        assert!(write_to(&store, &"new".repeat(2000)).is_err());
        assert_eq!(read_from(&store).unwrap().unwrap().as_str(), "old");
        assert_eq!(store.values.borrow().len(), 2);
    }
    #[test]
    fn corrupt_manifest_or_missing_chunk_fails_closed() {
        let store = Memory::default();
        write_to(&store, "old").unwrap();
        let m = manifest(&store).unwrap().unwrap();
        store.delete(&chunk_key(&m, 0));
        assert!(read_from(&store).is_err());
        store.values.borrow_mut().insert(
            MANIFEST.into(),
            r#"{"version":1,"generation":"bad","chunks":99999999}"#.into(),
        );
        assert!(read_from(&store).is_err());
    }
}
