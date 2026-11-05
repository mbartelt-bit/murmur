//! Local vocabulary with reversible evidence. Only user corrections are evidence.
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::sync::Mutex;
use tauri::AppHandle;
use tauri_plugin_store::StoreExt;

static WRITE_LOCK: Mutex<()> = Mutex::new(());
const STORE: &str = "personalization.json";
const MAX_TERMS: usize = 500;

#[derive(Clone, Serialize, Deserialize, Default)]
#[serde(default)]
pub struct Vocabulary {
    pub learning: bool,
    pub terms: Vec<Term>,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct Term {
    pub term: String,
    pub source: String,
    pub enabled: bool,
    #[serde(default)]
    pub evidence: BTreeMap<String, String>,
}
fn read(app: &AppHandle) -> Result<Vocabulary, String> {
    let store = app.store(STORE).map_err(|e| e.to_string())?;
    match store.get("vocabulary") {
        Some(v) => serde_json::from_value(v).map_err(|e| e.to_string()),
        None => Ok(Vocabulary::default()),
    }
}
fn mutate(
    app: &AppHandle,
    f: impl FnOnce(&mut Vocabulary) -> Result<(), String>,
) -> Result<Vocabulary, String> {
    let _guard = WRITE_LOCK.lock().map_err(|_| "Vocabulary is busy")?;
    let mut vocabulary = read(app)?;
    f(&mut vocabulary)?;
    let store = app.store(STORE).map_err(|e| e.to_string())?;
    let old = store.get("vocabulary");
    store.set(
        "vocabulary",
        serde_json::to_value(&vocabulary).map_err(|e| e.to_string())?,
    );
    if let Err(e) = store.save() {
        if let Some(old) = old {
            store.set("vocabulary", old);
        } else {
            store.delete("vocabulary");
        }
        return Err(e.to_string());
    }
    Ok(vocabulary)
}
fn valid_term(value: &str) -> Result<String, String> {
    let value = value.trim();
    if value.is_empty()
        || value.chars().count() > 80
        || value
            .chars()
            .any(|c| c.is_control() || c == '<' || c == '>')
    {
        return Err("Use a word or short phrase of up to 80 characters, on one line.".into());
    }
    Ok(value.to_owned())
}
/// Extract only a small changed phrase. Sentence rewrites and insertions are not
/// recognition corrections. Case is significant for preferred name spelling.
fn correction(before: &str, after: &str) -> Option<(String, String)> {
    let a: Vec<_> = before.split_whitespace().collect();
    let b: Vec<_> = after.split_whitespace().collect();
    let prefix = a.iter().zip(&b).take_while(|(x, y)| x == y).count();
    let suffix = a[prefix..]
        .iter()
        .rev()
        .zip(b[prefix..].iter().rev())
        .take_while(|(x, y)| x == y)
        .count();
    let old = &a[prefix..a.len() - suffix];
    let new = &b[prefix..b.len() - suffix];
    if old.is_empty() || new.is_empty() || old.len() > 3 || new.len() > 3 {
        return None;
    }
    let trim = |s: String| s.trim_matches(|c: char| !c.is_alphanumeric()).to_string();
    let old = trim(old.join(" "));
    let new = trim(new.join(" "));
    if old == new || !new.chars().any(char::is_alphabetic) {
        return None;
    }
    Some((valid_term(&old).ok()?, valid_term(&new).ok()?))
}
impl Vocabulary {
    fn observe(&mut self, id: i64, before: &str, after: &str) {
        // Re-editing or reverting one transcript cannot inflate confidence.
        let key = id.to_string();
        for term in &mut self.terms {
            term.evidence.remove(&key);
        }
        self.terms
            .retain(|t| t.source == "manual" || !t.evidence.is_empty());
        if !self.learning {
            return;
        }
        if let Some((old, new)) = correction(before, after) {
            if let Some(term) = self.terms.iter_mut().find(|t| t.term == new) {
                term.evidence.insert(key, old);
            } else if self.terms.len() < MAX_TERMS {
                self.terms.push(Term {
                    term: new,
                    source: "learned".into(),
                    enabled: true,
                    evidence: BTreeMap::from([(key, old)]),
                });
            }
        }
    }
    pub fn prompt(&self) -> String {
        let mut terms: Vec<_> = self
            .terms
            .iter()
            .filter(|t| {
                t.enabled && (t.source == "manual" || (self.learning && t.evidence.len() >= 2))
            })
            .collect();
        terms.sort_by_key(|t| (t.source != "manual", std::cmp::Reverse(t.evidence.len())));
        let mut result = String::new();
        for t in terms.into_iter().take(50) {
            if result.chars().count() + t.term.chars().count() + 2 > 700 {
                break;
            }
            if !result.is_empty() {
                result.push_str(", ");
            }
            result.push_str(&t.term);
        }
        result
    }
}
pub fn prompt(app: &AppHandle) -> String {
    read(app).map(|v| v.prompt()).unwrap_or_default()
}
#[tauri::command]
pub fn get_vocabulary(app: AppHandle) -> Result<Vocabulary, String> {
    read(&app)
}
#[tauri::command]
pub fn set_learning(app: AppHandle, enabled: bool) -> Result<Vocabulary, String> {
    mutate(&app, |v| {
        v.learning = enabled;
        Ok(())
    })
}
#[tauri::command]
pub fn add_word(app: AppHandle, term: String) -> Result<Vocabulary, String> {
    let term = valid_term(&term)?;
    mutate(&app, |v| {
        if let Some(t) = v.terms.iter_mut().find(|t| t.term == term) {
            t.source = "manual".into();
            t.enabled = true;
        } else {
            if v.terms.len() >= MAX_TERMS {
                return Err("Your vocabulary is full. Remove a word before adding another.".into());
            }
            v.terms.push(Term {
                term,
                source: "manual".into(),
                enabled: true,
                evidence: BTreeMap::new(),
            });
        }
        Ok(())
    })
}
#[tauri::command]
pub fn remove_word(app: AppHandle, term: String) -> Result<Vocabulary, String> {
    mutate(&app, |v| {
        v.terms.retain(|t| t.term != term);
        Ok(())
    })
}
#[tauri::command]
pub fn reset_vocabulary(app: AppHandle) -> Result<Vocabulary, String> {
    mutate(&app, |v| {
        v.terms.clear();
        Ok(())
    })
}
#[tauri::command]
pub fn learn_correction(
    app: AppHandle,
    id: i64,
    before: String,
    after: String,
) -> Result<Vocabulary, String> {
    if id <= 0 || before.len() > 100_000 || after.len() > 100_000 {
        return Err("Invalid correction".into());
    }
    mutate(&app, |v| {
        v.observe(id, &before, &after);
        Ok(())
    })
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn learns_only_from_distinct_corrections_and_reverts() {
        let mut v = Vocabulary {
            learning: true,
            ..Default::default()
        };
        v.observe(1, "Meet Mark today", "Meet Marc today");
        assert_eq!(v.prompt(), "");
        v.observe(1, "Meet Mark today", "Meet Marc today");
        assert_eq!(v.prompt(), "");
        v.observe(2, "Call Mark", "Call Marc");
        assert_eq!(v.prompt(), "Marc");
        v.observe(2, "Call Mark", "Call Mark");
        assert_eq!(v.prompt(), "");
    }
    #[test]
    fn rejects_rewrites_insertions_and_numbers() {
        assert!(correction("Hello", "Hello world").is_none());
        assert!(correction("Pay 12", "Pay 15").is_none());
        assert!(correction("one two three four", "five six seven eight").is_none());
        assert!(correction("Hello!", "Hello.").is_none());
    }
    #[test]
    fn disabled_learning_does_not_collect() {
        let mut v = Vocabulary::default();
        v.observe(1, "Mark", "Marc");
        assert!(v.terms.is_empty());
    }
    #[test]
    fn valid_terms_are_bounded() {
        assert!(valid_term("a\nb").is_err());
        assert!(valid_term("<instruction>").is_err());
        assert_eq!(valid_term("  José  ").unwrap(), "José");
    }
}
