//! The one token estimate. Everything the model is shown gets its count
//! here before it reaches the core: context blocks, new rows, tool
//! results. The core adds these up but never counts, and where the
//! provider has measured a request, its count wins; see "核心".

/// Tokens in `text`, by GPT-5's encoding. For other providers' models it
/// is an estimate, as is every count that isn't the provider's own.
pub fn count(text: &str) -> u32 {
    let tokens = tiktoken_rs::o200k_base_singleton().encode_ordinary(text);
    u32::try_from(tokens.len()).unwrap_or(u32::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counts() {
        assert_eq!(count(""), 0);
        assert_eq!(count("hello world"), 2);
        // Chinese runs about a token a character or two.
        let chinese = count("今天群里在聊示波器探头的补偿");
        assert!((5..=16).contains(&chinese), "{chinese}");
    }
}
