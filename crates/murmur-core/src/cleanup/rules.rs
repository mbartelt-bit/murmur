/// Offline cleanup: drop standalone filler words, capitalize sentences, ensure
/// terminal punctuation. Always available, never fails — the safety net behind
/// every cloud path.
pub struct RuleCleanup;

const FILLERS: &[&str] = &["um", "uh", "er", "erm", "hmm", "uhh", "umm"];

impl RuleCleanup {
    pub fn clean(&self, raw: &str) -> String {
        // 1. tokenize on whitespace, drop standalone filler words (case-insensitive)
        let kept: Vec<&str> = raw
            .split_whitespace()
            .filter(|w| {
                let bare = w.trim_matches(|c: char| !c.is_alphanumeric()).to_lowercase();
                !FILLERS.contains(&bare.as_str())
            })
            .collect();
        if kept.is_empty() { return String::new(); }
        let mut text = kept.join(" ");

        // 2. capitalize start of each sentence
        text = capitalize_sentences(&text);

        // 3. ensure terminal punctuation
        if !text.ends_with('.') && !text.ends_with('!') && !text.ends_with('?') {
            text.push('.');
        }
        text
    }
}

fn capitalize_sentences(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut cap_next = true;
    for ch in s.chars() {
        if cap_next && ch.is_alphabetic() {
            out.extend(ch.to_uppercase());
            cap_next = false;
        } else {
            out.push(ch);
            if ch == '.' || ch == '!' || ch == '?' { cap_next = true; }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    fn clean(s: &str) -> String { RuleCleanup.clean(s) }
    #[test] fn trims_and_collapses_whitespace() {
        assert_eq!(clean("  hello   world  "), "Hello world.");
    }
    #[test] fn removes_standalone_fillers() {
        assert_eq!(clean("um so uh this is er good"), "So this is good.");
    }
    #[test] fn capitalizes_sentences() {
        assert_eq!(clean("hello. how are you"), "Hello. How are you.");
    }
    #[test] fn keeps_filler_inside_words() {
        assert_eq!(clean("a number of umbrellas"), "A number of umbrellas.");
    }
    #[test] fn empty_stays_empty() { assert_eq!(clean("   "), ""); }
}
