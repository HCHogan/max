use std::collections::BTreeMap;

use super::*;

fn secret_file() -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("max-api-{:016x}", rand::random::<u64>()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("mail-api-key");
    std::fs::write(&file, "s3cret\n").unwrap();
    file
}

fn mail(base_url: &str) -> config::Api {
    let rule = |text: &str| Rule::try_from(text.to_owned()).unwrap();
    config::Api {
        base_url: base_url.to_owned(),
        secret_file: secret_file(),
        headers: BTreeMap::from([("Authorization".into(), "Bearer {secret}".into())]),
        query: BTreeMap::new(),
        allow: Some(vec![
            rule("POST /emails"),
            rule("GET /emails/*"),
            rule("GET /moved"),
        ]),
        per_hour: Some(3),
        about: "发邮件。".into(),
    }
}

#[test]
fn a_call_stays_below_the_base() {
    let mut api = mail("https://mail.example/v1/");
    api.query = BTreeMap::from([("key".into(), "{secret}".into())]);
    let api = Api::load(&api).unwrap();
    let url = |path: &str, query: Option<&str>| {
        api.url(path, query)
            .map(|(url, below)| (url.to_string(), below))
    };
    assert_eq!(
        url("/emails", Some("key=mine&page=2")),
        Some((
            "https://mail.example/v1/emails?page=2&key=s3cret".into(),
            "/emails".into()
        ))
    );
    assert_eq!(
        url("", None),
        Some(("https://mail.example/v1?key=s3cret".into(), "/".into()))
    );
    for away in [
        "/../emails",
        "/%2e%2E/emails",
        "/emails%2Fbatch",
        "/a%5C..%5Cb",
        "/emails/../../v2",
    ] {
        assert_eq!(url(away, None), None, "{away}");
    }
    // Normalized, it is still below.
    assert_eq!(
        url("/domains/../emails", None).map(|(_, below)| below),
        Some("/emails".into())
    );
}
