pub(super) mod rules;
mod cloud;
use tauri::AppHandle;
use tauri_plugin_store::StoreExt;

pub trait CleanupEngine { fn clean(&self, raw: &str) -> String; }
pub fn default_cleanup() -> Box<dyn CleanupEngine + Send + Sync> {
    Box::new(rules::RuleCleanup)
}

pub use cloud::CloudCleanup;

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

    if let Some(provider) = crate::provider::Provider::from_id(choice) {
        let key = crate::secrets::get(provider.key_account())
            .ok()
            .flatten()
            .unwrap_or_default();
        Box::new(cloud::CloudCleanup::new(provider.base_url(), provider.chat_model(), key))
    } else {
        Box::new(rules::RuleCleanup)
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
