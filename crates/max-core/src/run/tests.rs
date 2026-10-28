use super::*;
use crate::item::Protocol;

fn spec(window: u32, max_output: Option<u32>) -> RunSpec {
    RunSpec {
        model: ModelTag {
            protocol: Protocol::Responses,
            model: "m".into(),
        },
        window,
        max_output,
        max_tools: vec![],
    }
}

#[test]
fn the_limit() {
    // 400k window, 128k output: 252k available; 100k of base leaves 152k,
    // where half the window alone would allow 200k.
    assert_eq!(spec(400_000, Some(128_000)).limit(100_000), 152_000);
    assert_eq!(spec(400_000, Some(128_000)).limit(10_000), 200_000);
    assert_eq!(spec(10_000, None).limit(1_000), 5_000);
    assert_eq!(spec(10_000, None).limit(9_000), 0);
}
