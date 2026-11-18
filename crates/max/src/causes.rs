//! An error with what it came of, on one line: for a log, and for what a
//! failure line says in the chat.

use std::error::Error;

/// `error` and its causes, `: ` between them, as `{:#}` has a report's.
/// An error says what happened and leaves what that came of to its
/// source; a cause its error ends with all the same, as sqlx's database
/// error ends with its source, is left out.
pub fn chain(error: &(dyn Error + 'static)) -> String {
    let mut line = error.to_string();
    let mut source = error.source();
    while let Some(cause) = source {
        let said = cause.to_string();
        if !line.ends_with(&said) {
            line.push_str(": ");
            line.push_str(&said);
        }
        source = cause.source();
    }
    line
}
