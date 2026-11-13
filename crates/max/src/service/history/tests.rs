use super::*;
use crate::conversation::testing::offset;

#[test]
fn bounds_are_rows_moments_or_whole_local_days() {
    assert_eq!(bound(" #12 ", offset()).unwrap(), Bound::Row(MessageId(12)));
    let Bound::At(at) = bound("2026-10-03 12:30", offset()).unwrap() else {
        panic!("not a moment");
    };
    assert_eq!(at.to_rfc3339(), "2026-10-03T04:30:00+00:00");
    let Bound::Day(start, next) = bound("2026-10-03", offset()).unwrap() else {
        panic!("not a day");
    };
    assert_eq!(start.to_rfc3339(), "2026-10-02T16:00:00+00:00");
    assert_eq!(next.to_rfc3339(), "2026-10-03T16:00:00+00:00");
    for wrong in ["10-03", "#x", "#", "2026-10-03 25:00", "昨天"] {
        assert_eq!(bound(wrong, offset()).unwrap_err().code, "bad_arguments");
    }
}
