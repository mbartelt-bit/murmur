use murmur_core::{cleanup::RuleCleanup, CloudConfig};
use tauri::AppHandle;
use tauri_plugin_store::StoreExt;

pub trait CleanupEngine { fn clean(&self, raw: &str) -> String; }

impl CleanupEngine for RuleCleanup {
    fn clean(&self, raw: &str) -> String {
        RuleCleanup::clean(self, raw)
    }
}

pub fn default_cleanup() -> Box<dyn CleanupEngine + Send + Sync> {
    Box::new(RuleCleanup)
}

/// Desktop adapter over `murmur_core::clean_text`, which already falls back to
/// the rules engine on any cloud failure, so words are never lost.
pub struct CloudCleanup {
    cfg: CloudConfig,
}

impl CloudCleanup {
    pub fn new(cfg: CloudConfig) -> Self {
        Self { cfg }
    }
}

impl CleanupEngine for CloudCleanup {
    fn clean(&self, raw: &str) -> String {
        let call = murmur_core::clean_text(raw.to_owned(), Some(self.cfg.clone()));
        tauri::async_runtime::block_on(call).clean
    }
}

/// Resolve the stored "cleanup_engine" setting to a canonical choice string.
/// Returns "openai", "groq", or "rule" (default for any unrecognised/absent value).
pub(crate) fn cleanup_choice(stored: Option<&str>) -> &'static str {
    match stored {
        Some("openai") => "openai",
        Some("groq") => "groq",
        _ => "rule",
    }
}

/// Build the cleanup engine the user has selected (reads store + Keychain).
pub fn make_engine(app: &AppHandle) -> Box<dyn CleanupEngine + Send + Sync> {
    let stored = app
        .store("settings.json")
        .ok()
        .and_then(|s| s.get("cleanup_engine"))
        .and_then(|v| v.as_str().map(|s| s.to_owned()));

    let choice = cleanup_choice(stored.as_deref());

    if let Some(provider) = murmur_core::Provider::from_id(choice) {
        let api_key = crate::secrets::get(provider.key_account())
            .ok()
            .flatten()
            .unwrap_or_default();
        Box::new(CloudCleanup::new(CloudConfig { provider, api_key }))
    } else {
        Box::new(RuleCleanup)
    }
}

#[cfg(test)]
mod tests {
    use super::cleanup_choice;

    #[test]
    fn choice_openai() {
        assert_eq!(cleanup_choice(Some("openai")), "openai");
    }

    #[test]
    fn choice_groq() {
        assert_eq!(cleanup_choice(Some("groq")), "groq");
    }

    #[test]
    fn choice_rule_explicit() {
        assert_eq!(cleanup_choice(Some("rule")), "rule");
    }

    #[test]
    fn choice_missing_defaults_rule() {
        assert_eq!(cleanup_choice(None), "rule");
    }

    #[test]
    fn choice_garbage_defaults_rule() {
        assert_eq!(cleanup_choice(Some("bad")), "rule");
    }
}
