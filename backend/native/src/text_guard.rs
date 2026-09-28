//! Contact-leak scanning: does a chat message try to take a deal off BROKA?
//!
//! BROKA's money moves through escrow. The way a deal escapes it is always
//! the same: one side slips the other a phone number, a WhatsApp handle or
//! an M-Pesa till, and the payment happens where nobody can protect the
//! buyer. People who do it on purpose hide it - "zero seven one two...",
//! "0712 345 678", a Cyrillic "о" for a zero, a zero-width space inside
//! "whatsapp" - so the text is normalized before anything is matched.
//!
//! This is the Rust engine. `api/core/text_guard.py` holds a Python
//! reference implementation of exactly the same steps, used when the
//! extension isn't installed; `tests/test_native_parity.py` feeds both the
//! same adversarial text and requires identical output. Change one, change
//! the other.
//!
//! Why Rust here: every message a user sends is scanned, and the text is
//! whatever the sender chose. Python's `re` backtracks, so one unlucky
//! pattern can take seconds on a crafted message (a ReDoS) while holding the
//! event loop. The `regex` crate guarantees time linear in the input for
//! every pattern, including rules someone adds later, and the scan releases
//! the GIL.

use std::collections::HashMap;
use std::sync::LazyLock;

use regex::{Captures, Regex};
use serde::Deserialize;
use unicode_normalization::char::{decompose_canonical, is_combining_mark};
use unicode_normalization::UnicodeNormalization;

/// The rules both engines load. Embedded at compile time, so a build always
/// carries the rules it was tested with; the Python side compares this text
/// with the file on disk and refuses a stale build.
pub const RULES_JSON: &str = include_str!("../rules/contact_leaks.json");

/// Findings returned for one message, at most. A message is one person's
/// text: a hundred findings already says everything a caller can act on,
/// and the cap keeps a pasted megabyte of phone numbers from becoming a
/// megabyte of Python objects.
pub const MAX_FINDINGS: usize = 100;

pub const KIND_PHONE: &str = "phone";
pub const KIND_EMAIL: &str = "email";

/// One thing in a message that looks like an off-platform contact.
///
/// `start`/`end` are byte offsets into the NORMALIZED text (which is ASCII,
/// so they are character offsets too) and `text` is that slice - not the
/// original message, whose offsets normalization does not preserve.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct Finding {
    pub start: usize,
    pub end: usize,
    pub kind: String,
    pub text: String,
}

#[derive(Deserialize)]
struct RulesFile {
    version: u32,
    invisible: Vec<String>,
    digit_blocks: Vec<String>,
    homoglyphs: HashMap<String, String>,
    number_words: HashMap<String, String>,
    repeaters: HashMap<String, u32>,
    rules: Vec<RuleSpec>,
}

#[derive(Deserialize)]
struct RuleSpec {
    kind: String,
    name: String,
    pattern: String,
}

struct Rule {
    kind: String,
    regex: Regex,
}

/// The compiled rules. Built once per process from [`RULES_JSON`].
pub struct Engine {
    version: u32,
    invisible: Vec<(u32, u32)>,
    digit_blocks: Vec<u32>,
    homoglyphs: HashMap<char, char>,
    token_re: Regex,
    number_word_re: Regex,
    number_words: HashMap<String, char>,
    repeater_re: Regex,
    repeaters: HashMap<String, usize>,
    digit_run_re: Regex,
    rules: Vec<Rule>,
}

static ENGINE: LazyLock<Engine> = LazyLock::new(|| {
    // Only reachable with a broken rules file, which `cargo test` and the
    // Python parity suite both load before anything ships.
    Engine::from_json(RULES_JSON).expect("native/rules/contact_leaks.json is invalid")
});

/// The process-wide engine for the embedded rules.
pub fn engine() -> &'static Engine {
    &ENGINE
}

/// [`Engine::normalize`] with the embedded rules.
pub fn normalize(text: &str) -> String {
    engine().normalize(text)
}

/// [`Engine::scan`] with the embedded rules.
pub fn scan(text: &str) -> Vec<Finding> {
    engine().scan(text)
}

fn parse_code_point(hex: &str) -> Result<u32, String> {
    u32::from_str_radix(hex.trim(), 16).map_err(|e| format!("bad code point {hex:?}: {e}"))
}

fn parse_char(hex: &str) -> Result<char, String> {
    let cp = parse_code_point(hex)?;
    char::from_u32(cp).ok_or_else(|| format!("{hex:?} is not a Unicode scalar value"))
}

/// A single printable ASCII character, which is all a replacement may be:
/// normalized text is printable ASCII by construction.
fn parse_ascii_replacement(field: &str, key: &str, value: &str) -> Result<char, String> {
    let mut chars = value.chars();
    match (chars.next(), chars.next()) {
        (Some(c), None) if c.is_ascii_graphic() => Ok(c),
        _ => Err(format!(
            "{field}[{key:?}] must be one printable ASCII character, got {value:?}"
        )),
    }
}

/// `w1|w2|...` for a set of plain words, longest first so the alternation
/// order never depends on hash-map iteration order.
fn word_alternation<'a>(words: impl Iterator<Item = &'a String>) -> Result<String, String> {
    let mut words: Vec<&String> = words.collect();
    for w in &words {
        if w.is_empty() || !w.bytes().all(|b| b.is_ascii_lowercase()) {
            return Err(format!("{w:?} must be lowercase ASCII letters"));
        }
    }
    words.sort_by(|a, b| b.len().cmp(&a.len()).then(a.cmp(b)));
    Ok(words
        .iter()
        .map(|w| w.as_str())
        .collect::<Vec<_>>()
        .join("|"))
}

impl Engine {
    /// Compile a rules file. Every value is checked here, so a mistake in the
    /// JSON is an error naming the field rather than a wrong scan later.
    pub fn from_json(json: &str) -> Result<Engine, String> {
        let file: RulesFile = serde_json::from_str(json).map_err(|e| e.to_string())?;

        let mut invisible = Vec::with_capacity(file.invisible.len());
        for spec in &file.invisible {
            let (lo, hi) = match spec.split_once('-') {
                Some((lo, hi)) => (parse_code_point(lo)?, parse_code_point(hi)?),
                None => {
                    let cp = parse_code_point(spec)?;
                    (cp, cp)
                }
            };
            if lo > hi {
                return Err(format!("invisible range {spec:?} is backwards"));
            }
            invisible.push((lo, hi));
        }

        let digit_blocks = file
            .digit_blocks
            .iter()
            .map(|s| parse_code_point(s))
            .collect::<Result<Vec<_>, _>>()?;

        let mut homoglyphs = HashMap::with_capacity(file.homoglyphs.len());
        for (key, value) in &file.homoglyphs {
            let from = parse_char(key)?;
            if from.is_ascii() {
                return Err(format!("homoglyphs[{key:?}] is already ASCII"));
            }
            homoglyphs.insert(from, parse_ascii_replacement("homoglyphs", key, value)?);
        }

        let mut number_words = HashMap::with_capacity(file.number_words.len());
        for (word, digit) in &file.number_words {
            let d = parse_ascii_replacement("number_words", word, digit)?;
            if !d.is_ascii_digit() {
                return Err(format!(
                    "number_words[{word:?}] must be a digit, got {digit:?}"
                ));
            }
            number_words.insert(word.clone(), d);
        }

        let mut repeaters = HashMap::with_capacity(file.repeaters.len());
        for (word, times) in &file.repeaters {
            if !(2..=9).contains(times) {
                return Err(format!("repeaters[{word:?}] must be 2 to 9, got {times}"));
            }
            repeaters.insert(word.clone(), *times as usize);
        }

        let mut rules = Vec::with_capacity(file.rules.len());
        for spec in file.rules {
            if spec.kind.is_empty()
                || !spec
                    .kind
                    .bytes()
                    .all(|b| b.is_ascii_lowercase() || b == b'_')
            {
                return Err(format!(
                    "rule {:?}: kind {:?} must be snake_case",
                    spec.name, spec.kind
                ));
            }
            let regex =
                Regex::new(&spec.pattern).map_err(|e| format!("rule {:?}: {e}", spec.name))?;
            if regex.is_match("") {
                return Err(format!("rule {:?} matches empty text", spec.name));
            }
            rules.push(Rule {
                kind: spec.kind,
                regex,
            });
        }

        Ok(Engine {
            version: file.version,
            invisible,
            digit_blocks,
            homoglyphs,
            token_re: Regex::new(r"[a-z0-9]+").expect("static pattern"),
            number_word_re: Regex::new(&format!(
                r"\b(?:{})\b",
                word_alternation(number_words.keys())?
            ))
            .map_err(|e| e.to_string())?,
            number_words,
            repeater_re: Regex::new(&format!(
                r"\b({}) ?([0-9])",
                word_alternation(repeaters.keys())?
            ))
            .map_err(|e| e.to_string())?,
            repeaters,
            // A digit, then digits each preceded by at most three separators:
            // "0712 345 678", "+254 (0) 712-345-678", "0 7 1 2 ...". Commas
            // are not separators, so "1,200,000" never joins into a number.
            digit_run_re: Regex::new(r"[0-9](?:[ .()\-]{0,3}[0-9])*").expect("static pattern"),
            rules,
        })
    }

    /// The rules file's `version`.
    pub fn version(&self) -> u32 {
        self.version
    }

    fn is_invisible(&self, c: char) -> bool {
        let cp = c as u32;
        self.invisible.iter().any(|&(lo, hi)| lo <= cp && cp <= hi)
    }

    fn digit_of(&self, c: char) -> Option<char> {
        let cp = c as u32;
        self.digit_blocks
            .iter()
            .find(|&&start| start <= cp && cp < start + 10)
            .map(|&start| char::from(b'0' + (cp - start) as u8))
    }

    /// One character of lower-cased NFKC text, as printable ASCII: `None` to
    /// drop it, a space for anything that can't carry a contact detail.
    fn map_char(&self, c: char) -> Option<char> {
        if self.is_invisible(c) || is_combining_mark(c) {
            return None;
        }
        // The base letter of a precomposed character: "é" is "e".
        let mut base = c;
        let mut first = true;
        decompose_canonical(c, |d| {
            if first {
                base = d;
                first = false;
            }
        });
        if base.is_ascii() {
            return Some(if base.is_ascii_control() { ' ' } else { base });
        }
        if let Some(d) = self.digit_of(base) {
            return Some(d);
        }
        if let Some(&h) = self.homoglyphs.get(&base) {
            return Some(h);
        }
        Some(' ')
    }

    /// The text rules and number detection run on. In order:
    ///
    /// 1. NFKC, then lower case: fullwidth and styled letters and digits
    ///    ("ＷｈａｔｓＡｐｐ", "𝟎𝟕") become plain ones.
    /// 2. Per character: invisible characters and combining marks dropped,
    ///    accents stripped, other scripts' digits and look-alike letters
    ///    mapped, anything else non-ASCII (and every control character)
    ///    a space.
    /// 3. Runs of spaces collapsed to one; no space at either end.
    /// 4. In a token of letters and digits that has a digit, `o` is 0 and
    ///    `l`/`i` are 1, if those are its only letters: "O7l2" is 0712.
    /// 5. Number words, English and Swahili, become digits.
    /// 6. "double 7" is "7 7", "triple 0" is "0 0 0".
    pub fn normalize(&self, text: &str) -> String {
        let lowered = text.nfkc().collect::<String>().to_lowercase();

        let mut ascii = String::with_capacity(lowered.len());
        let mut after_space = true; // no leading space
        for c in lowered.chars() {
            match self.map_char(c) {
                None => {}
                Some(' ') => {
                    if !after_space {
                        ascii.push(' ');
                        after_space = true;
                    }
                }
                Some(m) => {
                    ascii.push(m);
                    after_space = false;
                }
            }
        }
        if ascii.ends_with(' ') {
            ascii.pop();
        }

        let tokens = self
            .token_re
            .replace_all(&ascii, |caps: &Captures| letters_as_digits(&caps[0]));
        let words = self.number_word_re.replace_all(&tokens, |caps: &Captures| {
            self.number_words[&caps[0]].to_string()
        });
        // Spaced out, so "zero seven double one..." stays a run of single
        // digits - the shape find_phones accepts for a spelled-out number.
        let repeated = self.repeater_re.replace_all(&words, |caps: &Captures| {
            vec![&caps[2]; self.repeaters[&caps[1]]].join(" ")
        });
        repeated.into_owned()
    }

    /// Everything in `text` that looks like an off-platform contact, sorted
    /// by position, at most [`MAX_FINDINGS`].
    pub fn scan(&self, text: &str) -> Vec<Finding> {
        let norm = self.normalize(text);
        let mut found = Vec::new();
        self.find_phones(&norm, &mut found);
        find_emails(&norm, &mut found);
        for rule in &self.rules {
            for m in rule.regex.find_iter(&norm) {
                found.push(finding(&norm, &rule.kind, m.start(), m.end()));
            }
        }
        found.sort();
        found.dedup();
        found.truncate(MAX_FINDINGS);
        found
    }

    /// Kenyan mobile numbers, however they're spaced.
    ///
    /// Inside each run of digits and separators, groups of digits are joined
    /// left to right until they spell a number; the shortest join from each
    /// group wins, so two numbers written side by side are two findings.
    ///
    /// Joining needs an anchor of 3 or more digits at the start: a first
    /// group that long ("0712 345 678", "+254 712 345 678"), or that many
    /// single digits in a row, as a number spelled out digit by digit reads
    /// ("zero seven one two 345 678" is "0 7 1 2 345 678"). A run of single
    /// digits alone may always join ("0 7 1 2 3 4 5 6 7 8"). Two-digit
    /// groups can't anchor: that is how a date and a time look, and
    /// "07.10.2025 12:30" is not a phone number.
    fn find_phones(&self, norm: &str, found: &mut Vec<Finding>) {
        for run in self.digit_run_re.find_iter(norm) {
            let groups = digit_groups(norm, run.start(), run.end());
            // singles_from[i]: how many single-digit groups start at i. One
            // backward pass - counting afresh for every i is quadratic in a
            // long run like "1 1 1 1 ...".
            let mut singles_from = vec![0usize; groups.len() + 1];
            for i in (0..groups.len()).rev() {
                if groups[i].1 - groups[i].0 == 1 {
                    singles_from[i] = singles_from[i + 1] + 1;
                }
            }
            let mut i = 0;
            while i < groups.len() {
                let (first_start, first_end) = groups[i];
                let anchor = match first_end - first_start {
                    1 => singles_from[i],
                    len => len,
                };
                let mut joined = String::new();
                let mut all_single = true;
                let mut matched = None;
                for (j, &(start, end)) in groups.iter().enumerate().skip(i) {
                    joined.push_str(&norm[start..end]);
                    all_single &= end - start == 1;
                    if joined.len() > 13 {
                        break;
                    }
                    if j > i && !all_single && anchor < 3 {
                        break;
                    }
                    if is_kenyan_mobile(&joined) {
                        matched = Some(j);
                        break;
                    }
                }
                match matched {
                    Some(j) => {
                        found.push(finding(norm, KIND_PHONE, first_start, groups[j].1));
                        i = j + 1;
                    }
                    None => i += 1,
                }
            }
        }
    }
}

fn finding(norm: &str, kind: &str, start: usize, end: usize) -> Finding {
    Finding {
        start,
        end,
        kind: kind.to_owned(),
        text: norm[start..end].to_owned(),
    }
}

/// Step 4 of [`Engine::normalize`] for one token.
fn letters_as_digits(token: &str) -> String {
    let has_digit = token.bytes().any(|b| b.is_ascii_digit());
    let only_lookalikes = token
        .bytes()
        .all(|b| b.is_ascii_digit() || matches!(b, b'o' | b'l' | b'i'));
    if !(has_digit && only_lookalikes) {
        return token.to_owned();
    }
    token
        .chars()
        .map(|c| match c {
            'o' => '0',
            'l' | 'i' => '1',
            other => other,
        })
        .collect()
}

/// Byte ranges of the digit groups in `norm[start..end]`.
fn digit_groups(norm: &str, start: usize, end: usize) -> Vec<(usize, usize)> {
    let bytes = norm.as_bytes();
    let mut groups = Vec::new();
    let mut i = start;
    while i < end {
        if bytes[i].is_ascii_digit() {
            let s = i;
            while i < end && bytes[i].is_ascii_digit() {
                i += 1;
            }
            groups.push((s, i));
        } else {
            i += 1;
        }
    }
    groups
}

/// 07XXXXXXXX / 01XXXXXXXX, the same with 254 in front of the 7 or 1, or
/// with 254 in front of the leading 0 ("+254 (0) 712...").
fn is_kenyan_mobile(digits: &str) -> bool {
    let d = digits.as_bytes();
    let mobile = |b: u8| b == b'1' || b == b'7';
    match d.len() {
        10 => d[0] == b'0' && mobile(d[1]),
        12 => digits.starts_with("254") && mobile(d[3]),
        13 => digits.starts_with("2540") && mobile(d[4]),
        _ => false,
    }
}

fn is_local_part(b: u8) -> bool {
    b.is_ascii_lowercase() || b.is_ascii_digit() || matches!(b, b'.' | b'_' | b'%' | b'+' | b'-')
}

fn is_domain_part(b: u8) -> bool {
    b.is_ascii_lowercase() || b.is_ascii_digit() || matches!(b, b'.' | b'-')
}

/// Addresses written out with an "@". Found by walking outwards from each
/// "@" rather than with a regex, so the Python engine can do the same in
/// linear time (a backtracking email regex is the classic ReDoS).
fn find_emails(norm: &str, found: &mut Vec<Finding>) {
    let bytes = norm.as_bytes();
    for (at, _) in norm.match_indices('@') {
        let mut start = at;
        while start > 0 && is_local_part(bytes[start - 1]) {
            start -= 1;
        }
        let mut end = at + 1;
        while end < bytes.len() && is_domain_part(bytes[end]) {
            end += 1;
        }
        // "mail me at jo@example.com." - the full stop ends the sentence.
        while end > at + 1 && matches!(bytes[end - 1], b'.' | b'-') {
            end -= 1;
        }
        let local = &norm[start..at];
        let domain = &norm[at + 1..end];
        if !local.bytes().any(|b| b.is_ascii_alphanumeric()) {
            continue; // "@handle" is not an address
        }
        if domain.starts_with('.') || domain.contains("..") {
            continue;
        }
        let Some((_, tld)) = domain.rsplit_once('.') else {
            continue;
        };
        if tld.len() < 2 || !tld.bytes().all(|b| b.is_ascii_lowercase()) {
            continue;
        }
        found.push(finding(norm, KIND_EMAIL, start, end));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn kinds(text: &str) -> Vec<String> {
        scan(text).into_iter().map(|f| f.kind).collect()
    }

    #[test]
    fn embedded_rules_compile() {
        let engine = Engine::from_json(RULES_JSON).expect("rules must load");
        assert_eq!(engine.version(), 1);
    }

    #[test]
    fn normalizes_disguised_text() {
        assert_eq!(normalize("  Call   ME\n\tnow "), "call me now");
        assert_eq!(normalize("ＷｈａｔｓＡｐｐ"), "whatsapp");
        assert_eq!(normalize("whats\u{200B}app"), "whatsapp");
        assert_eq!(normalize("Wh\u{0430}ts\u{0430}pp"), "whatsapp"); // Cyrillic a
        assert_eq!(normalize("caf\u{00E9} cafe\u{0301}"), "cafe cafe");
        assert_eq!(normalize("O7l2 345 678"), "0712 345 678");
        assert_eq!(normalize("zero seven double two"), "0 7 2 2");
        assert_eq!(normalize("sifuri saba moja"), "0 7 1");
        assert_eq!(normalize("\u{0660}\u{0667}"), "07"); // Arabic-Indic digits
        assert_eq!(normalize("price 😀 5k"), "price 5k");
        assert_eq!(normalize("hello oil boil"), "hello oil boil"); // no digit: untouched
    }

    #[test]
    fn finds_phone_numbers_in_every_common_shape() {
        for text in [
            "0712345678",
            "call 0712 345 678",
            "0712-345-678",
            "+254 712 345 678",
            "254712345678",
            "+254 (0) 712 345 678",
            "0 7 1 2 3 4 5 6 7 8",
            "zero seven one two three four five six seven eight",
            "sifuri saba moja mbili tatu nne tano sita saba nane",
            "zero seven double one 345 678 nine",
            "O7l2345678",
            "０７１２３４５６７８",
            "0110 123 456",
        ] {
            assert!(
                scan(text).iter().any(|f| f.kind == KIND_PHONE),
                "missed a phone number in {text:?}"
            );
        }
    }

    #[test]
    fn two_numbers_side_by_side_are_two_findings() {
        let found = scan("0712345678 0733123456");
        let phones: Vec<_> = found.iter().filter(|f| f.kind == KIND_PHONE).collect();
        assert_eq!(phones.len(), 2);
        assert_eq!(phones[0].text, "0712345678");
        assert_eq!(phones[1].text, "0733123456");
    }

    #[test]
    fn prices_dates_and_ids_are_not_phone_numbers() {
        for text in [
            "KES 1,200,000",
            "price 071",
            "delivery 07.10.2025 12:30",
            "IMEI 356938035643809",
            "07123456789",
            "0612345678",
            "1 500 000",
            "order 12345",
        ] {
            assert!(
                !scan(text).iter().any(|f| f.kind == KIND_PHONE),
                "false phone number in {text:?}"
            );
        }
    }

    #[test]
    fn finds_email_addresses() {
        assert_eq!(kinds("mail jo.doe+ads@example.co.ke."), vec![KIND_EMAIL]);
        assert_eq!(kinds("jo at gmail dot com"), vec![KIND_EMAIL]);
        assert!(kinds("follow @broka_ke").is_empty());
        assert!(kinds("a@b").is_empty());
        assert!(kinds("x@y.c").is_empty());
    }

    #[test]
    fn finds_rule_matches() {
        assert_eq!(kinds("WhatsApp me"), vec!["messaging_app"]);
        assert_eq!(kinds("what sapp"), vec!["messaging_app"]);
        assert_eq!(kinds("wh@ts@pp"), vec!["messaging_app"]);
        assert_eq!(kinds("pay me directly"), vec!["payment_redirect"]);
        assert_eq!(kinds("tuma pesa moja kwa moja"), vec!["payment_redirect"]);
        assert_eq!(kinds("till no. 123456"), vec!["payment_redirect"]);
        assert_eq!(kinds("nipigie"), vec!["contact_request"]);
    }

    #[test]
    fn ordinary_marketplace_talk_is_clean() {
        for text in [
            "Is the iPhone 13 still available?",
            "Can you do 45,000?",
            "Whats up, is it in good condition",
            "I'll pay through the app once you confirm",
            "Kitu moja tu, bei gani?",
            "my line of business is phones",
            "I want to buy goods from your store",
        ] {
            assert!(
                scan(text).is_empty(),
                "false finding in {text:?}: {:?}",
                scan(text)
            );
        }
    }

    #[test]
    fn findings_are_capped() {
        let text = "0712345678 ".repeat(MAX_FINDINGS * 3);
        assert_eq!(scan(&text).len(), MAX_FINDINGS);
    }

    #[test]
    fn huge_hostile_input_is_linear() {
        // Long runs that backtracking engines choke on: digits with no
        // phone, "@" with no address, separators with no digit.
        let text = format!(
            "{}{}{}{}",
            "1 ".repeat(200_000),
            "a".repeat(200_000),
            "@".repeat(50_000),
            "what ".repeat(50_000)
        );
        let started = std::time::Instant::now();
        let _ = scan(&text);
        assert!(
            started.elapsed().as_secs() < 5,
            "scan took {:?}",
            started.elapsed()
        );
    }

    #[test]
    fn rejects_bad_rules() {
        let base: serde_json::Value = serde_json::from_str(RULES_JSON).unwrap();
        let broken = |path: &str, value: serde_json::Value| {
            let mut v = base.clone();
            *v.pointer_mut(path).unwrap() = value;
            Engine::from_json(&v.to_string()).err()
        };
        assert!(broken("/rules/0/pattern", "(".into()).is_some());
        assert!(broken("/rules/0/pattern", "a*".into()).is_some());
        assert!(broken("/rules/0/kind", "Bad Kind".into()).is_some());
        assert!(broken("/homoglyphs/0430", "ab".into()).is_some());
        assert!(broken("/number_words/zero", "x".into()).is_some());
        assert!(broken("/repeaters/double", 1.into()).is_some());
        assert!(broken("/invisible/0", "ZZZZ".into()).is_some());
    }
}
