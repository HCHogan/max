-- |
-- The curated QQ built-in face (小黄脸) roster — the single source of
-- truth for which faces the model may use.  "Max.Prompt" renders it
-- into the system-prompt对照表 so the model can pick ids for
-- @[face#\<id\>]@ sends, and "Max.Handler" resolves the names the model
-- writes in @[silence:\<名\>]@ reactions against the same list.
--
-- Ids are QSid values verified against NapCat's @face_config.json@;
-- the selection deliberately skips hidden (@QHide@), deprecated and
-- seasonal entries so the model never sends something modern clients
-- render badly.  Keep the groups small and expressive — this table is
-- part of the static prompt prefix, so every entry costs tokens on
-- every dispatch (cached, but not free).
module Max.Faces
  ( curatedFaceGroups,
    curatedFaces,
    faceIdByName,
    faceNameById,
  )
where

import Data.Text (Text)

-- | The roster, grouped by mood for prompt display.  Group labels are
-- prompt-facing text; entries are @(名字, QSid)@.
curatedFaceGroups :: [(Text, [(Text, Int)])]
curatedFaceGroups =
  [ ( "笑",
      [ ("微笑", 14),
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
        ("耶", 355)
      ]
    ),
    ( "捧场",
      [ ("赞", 76),
        ("点赞", 201),
        ("鼓掌", 99),
        ("牛啊", 299),
        ("666", 356),
        ("崇拜", 318),
        ("比心", 319),
        ("庆祝", 320),
        ("打call", 311),
        ("喝彩", 144)
      ]
    ),
    ( "惊疑",
      [ ("惊讶", 0),
        ("疑问", 32),
        ("问号脸", 268),
        ("惊恐", 26),
        ("晕", 34),
        ("吓", 110)
      ]
    ),
    ( "围观",
      [ ("吃瓜", 271),
        ("暗中观察", 269),
        ("摸鱼", 285),
        ("嘘", 33),
        ("偷感", 427)
      ]
    ),
    ( "哭惨",
      [ ("流泪", 5),
        ("大哭", 9),
        ("委屈", 106),
        ("可怜", 111),
        ("难过", 15),
        ("快哭了", 107),
        ("我酸了", 273)
      ]
    ),
    ( "无语",
      [ ("尴尬", 10),
        ("擦汗", 97),
        ("流汗", 27),
        ("无奈", 174),
        ("白眼", 22),
        ("鄙视", 105),
        ("嫌弃", 323),
        ("呵呵哒", 272),
        ("面无表情", 284),
        ("emm", 270),
        ("撇嘴", 1)
      ]
    ),
    ( "怒",
      [ ("发怒", 11),
        ("生气", 326),
        ("拳头", 120)
      ]
    ),
    ( "崩溃",
      [ ("裂开", 357),
        ("捂脸", 264),
        ("脑阔疼", 262),
        ("衰", 36),
        ("辣眼睛", 265),
        ("我想开了", 338),
        ("大怨种", 344),
        ("我方了", 343)
      ]
    ),
    ( "困",
      [ ("困", 25),
        ("哈欠", 104)
      ]
    ),
    ( "亲近",
      [ ("拥抱", 49),
        ("贴贴", 350),
        ("爱心", 66),
        ("喵喵", 307),
        ("汪汪", 277)
      ]
    ),
    ( "礼节",
      [ ("握手", 78),
        ("抱拳", 118),
        ("敬礼", 282),
        ("拜谢", 297),
        ("拜托", 353),
        ("OK", 124),
        ("NO", 123),
        ("收到", 428),
        ("再见", 39)
      ]
    ),
    ( "其他",
      [ ("托腮", 212),
        ("尊嘟假嘟", 354),
        ("举牌牌", 332),
        ("幽灵", 187)
      ]
    )
  ]

-- | The roster flattened to @(名字, QSid)@ pairs.
curatedFaces :: [(Text, Int)]
curatedFaces = concatMap snd curatedFaceGroups

-- | Resolve a face name the model wrote (e.g. in @[silence:吃瓜]@) to
-- its QSid.  Exact match only — unknown names fall back to the
-- caller's default rather than guessing.
faceIdByName :: Text -> Maybe Int
faceIdByName n = lookup n curatedFaces

-- | The other direction, for reading a face back out of the ledger: a QQ
-- 贴表情 records only the QSid, so a transcript line would otherwise say
-- "贴了表情 212" and leave the model to guess.  Unknown ids stay numeric
-- rather than being described as something they are not.
faceNameById :: Int -> Maybe Text
faceNameById i = lookup i [(qsid, name) | (name, qsid) <- curatedFaces]
