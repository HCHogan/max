//! The QQ faces offered to the model, by name. QSids come from NapCat's
//! face_config.json, leaving out hidden, deprecated and seasonal ones. The
//! table goes into the system prompt, so it stays small.

use crate::ids::FaceId;

/// Grouped by mood for the prompt. Entries are (name, QSid).
pub const GROUPS: &[(&str, &[(&str, u32)])] = &[
    (
        "笑",
        &[
            ("微笑", 14),
            ("呲牙", 13),
            ("憨笑", 28),
            ("偷笑", 20),
            ("坏笑", 101),
            ("斜眼笑", 178),
            ("笑哭", 182),
            ("狂笑", 283),
            ("无眼笑", 281),
            ("doge", 179),
            ("得意", 4),
            ("调皮", 12),
            ("酷", 16),
            ("可爱", 21),
            ("卖萌", 175),
            ("耶", 355),
        ],
    ),
    (
        "捧场",
        &[
            ("赞", 76),
            ("点赞", 201),
            ("鼓掌", 99),
            ("牛啊", 299),
            ("666", 356),
            ("崇拜", 318),
            ("比心", 319),
            ("庆祝", 320),
            ("打call", 311),
            ("喝彩", 144),
        ],
    ),
    (
        "惊疑",
        &[
            ("惊讶", 0),
            ("疑问", 32),
            ("问号脸", 268),
            ("惊恐", 26),
            ("晕", 34),
            ("吓", 110),
        ],
    ),
    (
        "围观",
        &[
            ("吃瓜", 271),
            ("暗中观察", 269),
            ("摸鱼", 285),
            ("嘘", 33),
            ("偷感", 427),
        ],
    ),
    (
        "哭惨",
        &[
            ("流泪", 5),
            ("大哭", 9),
            ("委屈", 106),
            ("可怜", 111),
            ("难过", 15),
            ("快哭了", 107),
            ("我酸了", 273),
        ],
    ),
    (
        "无语",
        &[
            ("尴尬", 10),
            ("擦汗", 97),
            ("流汗", 27),
            ("无奈", 174),
            ("白眼", 22),
            ("鄙视", 105),
            ("嫌弃", 323),
            ("呵呵哒", 272),
            ("面无表情", 284),
            ("emm", 270),
            ("撇嘴", 1),
        ],
    ),
    ("怒", &[("发怒", 11), ("生气", 326), ("拳头", 120)]),
    (
        "崩溃",
        &[
            ("裂开", 357),
            ("捂脸", 264),
            ("脑阔疼", 262),
            ("衰", 36),
            ("辣眼睛", 265),
            ("我想开了", 338),
            ("大怨种", 344),
            ("我方了", 343),
        ],
    ),
    ("困", &[("困", 25), ("哈欠", 104)]),
    (
        "亲近",
        &[
            ("拥抱", 49),
            ("贴贴", 350),
            ("爱心", 66),
            ("喵喵", 307),
            ("汪汪", 277),
        ],
    ),
    (
        "礼节",
        &[
            ("握手", 78),
            ("抱拳", 118),
            ("敬礼", 282),
            ("拜谢", 297),
            ("拜托", 353),
            ("OK", 124),
            ("NO", 123),
            ("收到", 428),
            ("再见", 39),
        ],
    ),
    (
        "其他",
        &[
            ("托腮", 212),
            ("尊嘟假嘟", 354),
            ("举牌牌", 332),
            ("幽灵", 187),
        ],
    ),
];

fn all() -> impl Iterator<Item = (&'static str, u32)> {
    GROUPS.iter().flat_map(|(_, faces)| faces.iter().copied())
}

/// A face's name, for showing it to the model when the platform gave none.
/// Ids outside the table have no name rather than a guessed one.
pub fn name(face: FaceId) -> Option<&'static str> {
    all().find(|(_, id)| *id == face.0).map(|(n, _)| n)
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;

    use super::*;

    #[test]
    fn names_and_ids_are_unique() {
        let names: HashSet<_> = all().map(|(n, _)| n).collect();
        let ids: HashSet<_> = all().map(|(_, id)| id).collect();
        assert_eq!(names.len(), all().count());
        assert_eq!(ids.len(), all().count());
    }

    #[test]
    fn lookups() {
        assert_eq!(name(FaceId(271)), Some("吃瓜"));
        assert_eq!(name(FaceId(212)), Some("托腮"));
        assert_eq!(name(FaceId(9999)), None);
    }
}
