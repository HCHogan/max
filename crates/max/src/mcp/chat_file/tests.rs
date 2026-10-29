use max_core::ids::ConversationId;
use max_core::message::MediaKind;

use super::*;

#[test]
fn handles() {
    let at = |message, ordinal| Some((MessageId(message), ordinal));
    assert_eq!(parse("file#294934.0"), at(294_934, 0));
    assert_eq!(parse(" [file#7.2: 周报.pdf] "), at(7, 2));
    assert_eq!(parse("[image#7.0]"), at(7, 0));
    for bad in [
        "#7.0",
        "picture#7.0",
        "file#7",
        "file#x.0",
        "file#7.-1",
        "7.0",
    ] {
        assert_eq!(parse(bad), None, "{bad}");
    }
}

#[test]
fn names() {
    let stored = |name: Option<&str>, mime: Option<&str>| Stored {
        conversation: ConversationId(1),
        kind: MediaKind::File,
        name: name.map(str::to_owned),
        sha256: String::new(),
        mime: mime.map(str::to_owned),
        size: 0,
    };
    let named = |name, mime| file_name(MessageId(7), 1, &stored(name, mime));
    assert_eq!(named(Some(" 周报.pdf "), None), "7.1-周报.pdf");
    assert_eq!(named(Some("../a/b\n.txt"), None), "7.1-.._a_b_.txt");
    assert_eq!(named(Some(" "), Some("image/jpeg")), "7.1.jpg");
    assert_eq!(named(None, Some("video/mp4")), "7.1.mp4");
    assert_eq!(named(None, Some("application/octet-stream")), "7.1");
    assert_eq!(named(None, None), "7.1");
    let long = "长".repeat(100);
    assert_eq!(cleaned(&long).len(), LONGEST_NAME);
}
