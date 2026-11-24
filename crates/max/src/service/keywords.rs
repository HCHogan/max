//! Keywords, as `history` and `find_stickers` take them: words between
//! spaces, each found as written, whatever its case, as a substring of
//! lowercased text, with no word segmentation. See "Recall".

use super::Failure;

/// The most keywords in a query.
pub(super) const MOST_TERMS: usize = 8;
/// The most characters of a keyword, or of a name looked for.
pub(super) const TERM_CHARS: usize = 50;

/// `query`'s keywords, lowercased as the database does, each once; for
/// `tool`, which a mistake names.
pub(super) fn terms(tool: &str, query: &str) -> Result<Vec<String>, Failure> {
    let mut terms: Vec<String> = Vec::new();
    for word in query.split_whitespace() {
        let word: String = fold(word).into_iter().collect();
        if word.chars().count() > TERM_CHARS {
            return Err(Failure::new(
                "bad_arguments",
                format!("a keyword is at most {TERM_CHARS} characters"),
            ));
        }
        if !terms.contains(&word) {
            terms.push(word);
        }
    }
    if terms.is_empty() {
        return Err(Failure::new(
            "bad_arguments",
            format!("{tool}: query is empty"),
        ));
    }
    if terms.len() > MOST_TERMS {
        return Err(Failure::new(
            "bad_arguments",
            format!("at most {MOST_TERMS} keywords"),
        ));
    }
    Ok(terms)
}

/// `text` lowercased a character at a time, as Postgres's `lower` does, so
/// positions stay put.
pub(super) fn fold(text: &str) -> Vec<char> {
    text.chars()
        .map(|c| c.to_lowercase().next().unwrap_or(c))
        .collect()
}

/// A LIKE pattern that finds `term` anywhere.
pub(super) fn pattern(term: &str) -> String {
    let mut out = String::from("%");
    for c in term.chars() {
        if matches!(c, '%' | '_' | '\\') {
            out.push('\\');
        }
        out.push(c);
    }
    out.push('%');
    out
}
