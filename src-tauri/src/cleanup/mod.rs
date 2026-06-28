mod rules;
pub trait CleanupEngine { fn clean(&self, raw: &str) -> String; }
pub fn default_cleanup() -> Box<dyn CleanupEngine + Send + Sync> {
    Box::new(rules::RuleCleanup)
}
