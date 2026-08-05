module Max.IR.LowerSpec (spec) where

import Data.Aeson (Value (String), object, (.=))
import Data.ByteString qualified as BS
import Data.Foldable (for_)
import Data.Maybe (fromJust, fromMaybe, isJust)
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Max.IR
import Max.IR.Lower
import Max.Platform.Types
  ( NativeEventId (..),
    NativeUserId (..),
    Platform (..),
    PrincipalIdentityId (..),
  )
import Test.Hspec

knownIdentity :: PrincipalIdentityId
knownIdentity = PrincipalIdentityId 7

baseEnv :: LowerEnv
baseEnv =
  LowerEnv
    { platform = PlatformMatrix,
      caps = textOnlyCaps,
      attribution = Nothing,
      mentionNative = \pid ->
        if pid == knownIdentity then Just (NativeUserId "123456") else Nothing,
      mediaResolve = Just . ResolvedUrl . renderMediaRef,
      replyTarget = Nothing
    }

mkMeta :: MediaKind -> Maybe Text -> MediaMeta
mkMeta kind description =
  MediaMeta
    { kind,
      mime = Nothing,
      sizeBytes = Nothing,
      name = Nothing,
      description,
      raw = Nothing
    }

mentionNode :: Node 'Canonical
mentionNode = NMention (MentionIdentity knownIdentity) "张三"

qqFace :: Emote
qqFace = Emote PlatformQQ "5" (Just "惊讶") Nothing

blob :: Text -> MediaRef
blob marker = fromJust (mediaBlobRef (T.replicate 64 marker))

remote :: Text -> MediaRef
remote = fromJust . mediaRemoteRef

flat :: LoweredMessage -> [Node 'Lowered]
flat lowered = concat lowered.chunks

chunkBytes :: [Node 'Lowered] -> Int
chunkBytes = sum . map cost
  where
    cost = \case
      NText t -> BS.length (TE.encodeUtf8 t)
      NMention _ d -> BS.length (TE.encodeUtf8 ("@" <> d))
      _ -> 0

spec :: Spec
spec = do
  mentionSpec
  emoteSpec
  mediaSpec
  structureSpec
  replySpec
  chunkSpec
  capsCodecSpec
  invariantSpec

mentionSpec :: Spec
mentionSpec = describe "mention lowering" $ do
  it "keeps a native mention when the identity maps" $ do
    let out = lower baseEnv {caps = textOnlyCaps {mention = TierNative}} (Body [mentionNode])
    flat out `shouldBe` [NMention (NativeUserId "123456") "张三"]
    out.notes `shouldBe` []

  it "folds to @display when the identity is missing on the endpoint" $ do
    let env = baseEnv {caps = textOnlyCaps {mention = TierNative}, mentionNative = const Nothing}
        out = lower env (Body [mentionNode])
    flat out `shouldBe` [NText "@张三"]
    out.notes `shouldBe` [LowerNote "mention" NoteFolded (Just "no identity on endpoint")]

  it "folds on the text tier and records the degradation" $ do
    let out = lower baseEnv (Body [mentionNode, NText " 在吗"])
    flat out `shouldBe` [NText "@张三 在吗"]
    out.notes `shouldBe` [LowerNote "mention" NoteFolded Nothing]

  it "drops on the drop tier, keeping the audit note" $ do
    let out = lower baseEnv {caps = textOnlyCaps {mention = TierDrop}} (Body [mentionNode, NText "hi"])
    flat out `shouldBe` [NText "hi"]
    out.notes `shouldBe` [LowerNote "mention" NoteDropped (Just "张三")]

  it "folds mention-all even on the native tier" $ do
    let out =
          lower
            baseEnv {caps = textOnlyCaps {mention = TierNative}}
            (Body [NMention MentionAll "全体成员"])
    flat out `shouldBe` [NText "@全体成员"]
    out.notes `shouldBe` [LowerNote "mention" NoteFolded (Just "mention-all not native")]

emoteSpec :: Spec
emoteSpec = describe "emote lowering" $ do
  it "keeps a same-origin emote on the native tier" $ do
    let env = baseEnv {platform = PlatformQQ, caps = textOnlyCaps {emote = TierNative}}
        out = lower env (Body [NEmote qqFace])
    flat out `shouldBe` [NEmote qqFace]

  it "folds a foreign-origin emote despite the native tier" $ do
    let out = lower baseEnv {caps = textOnlyCaps {emote = TierNative}} (Body [NEmote qqFace])
    flat out `shouldBe` [NText "[表情: 惊讶]"]
    out.notes `shouldBe` [LowerNote "emote" NoteFolded (Just "origin mismatch")]

  it "drops quietly when declared" $ do
    let out = lower baseEnv {caps = textOnlyCaps {emote = TierDrop}} (Body [NText "好", NEmote qqFace])
    flat out `shouldBe` [NText "好"]
    out.notes `shouldBe` [LowerNote "emote" NoteDropped Nothing]

mediaSpec :: Spec
mediaSpec = describe "media lowering" $ do
  let img ref = NMedia ref (mkMeta MImage (Just "两只猫"))
      nativeImages = textOnlyCaps {image = TierNative, maxNativeMedia = 1}

  it "keeps resolved media on the native tier" $ do
    let out = lower baseEnv {caps = nativeImages} (Body [img (Just (blob "a"))])
    flat out `shouldBe` [NMedia (ResolvedUrl ("blob:" <> T.replicate 64 "a")) (mkMeta MImage (Just "两只猫"))]
    out.notes `shouldBe` []

  it "folds past the native media budget" $ do
    let out =
          lower
            baseEnv {caps = nativeImages}
            (Body [img (Just (blob "a")), img (Just (blob "b"))])
    flat out
      `shouldBe` [ NMedia (ResolvedUrl ("blob:" <> T.replicate 64 "a")) (mkMeta MImage (Just "两只猫")),
                   NText "[图片: 两只猫]"
                 ]
    out.notes `shouldBe` [LowerNote "image" NoteFolded (Just "media budget")]

  it "folds sourceless and unresolvable media with distinct reasons" $ do
    let env = baseEnv {caps = nativeImages, mediaResolve = const Nothing}
        out = lower env (Body [img Nothing, img (Just (blob "c"))])
    flat out `shouldBe` [NText "[图片: 两只猫][图片: 两只猫]"]
    out.notes
      `shouldBe` [ LowerNote "image" NoteFolded (Just "no source"),
                   LowerNote "image" NoteFolded (Just "unresolvable source")
                 ]

  it "keeps the clickable URL when folding remote media, never a blob ref" $ do
    let out =
          lower
            baseEnv
            (Body [img (Just (remote "https://x/a.png")), img (Just (blob "d"))])
    flat out `shouldBe` [NText "[图片: 两只猫] https://x/a.png[图片: 两只猫]"]

  it "drops with the fallback recorded in the note" $ do
    let out =
          lower
            baseEnv {caps = textOnlyCaps {video = TierDrop}}
            (Body [NMedia Nothing (mkMeta MVideo Nothing), NText "看"])
    flat out `shouldBe` [NText "看"]
    out.notes `shouldBe` [LowerNote "video" NoteDropped (Just "[视频]")]

structureSpec :: Spec
structureSpec = describe "structure" $ do
  it "prefixes attribution once, merged into the text" $ do
    let env = baseEnv {attribution = Just (Attribution "QQ" (Just "张三"))}
        out = lower env (Body [NText "你好"])
    flat out `shouldBe` [NText "[QQ · 张三] 你好"]

  it "suppresses entirely instead of sending a bare attribution prefix" $ do
    let env =
          baseEnv
            { attribution = Just (Attribution "QQ" (Just "张三")),
              caps = textOnlyCaps {mention = TierDrop}
            }
        out = lower env (Body [mentionNode])
    out.chunks `shouldBe` []

  it "always folds forwards and unsupported nodes" $ do
    let out =
          lower
            baseEnv
            (Body [NForward (ForwardRef "f" (Just 2)), NUnsupported (Unsupported "qq:record" "语音消息" Nothing)])
    flat out `shouldBe` [NText "[聊天记录: 2条][语音消息]"]
    map (.subject) out.notes `shouldBe` ["forward", "unsupported"]

  it "keeps a native card only with a captured wire payload" $ do
    let c = Card (Just "标题") Nothing (Just "https://e.com") Nothing Nothing (Just (String "wire"))
        semanticOnly = Card (Just "标题") Nothing (Just "https://e.com") Nothing Nothing Nothing
    flat (lower baseEnv {caps = textOnlyCaps {card = TierNative}} (Body [NCard c]))
      `shouldBe` [NCard c]
    flat (lower baseEnv {caps = textOnlyCaps {card = TierNative}} (Body [NCard semanticOnly]))
      `shouldBe` [NText "[分享: 标题 | https://e.com]"]
    flat (lower baseEnv (Body [NCard c]))
      `shouldBe` [NText "[分享: 标题 | https://e.com]"]

replySpec :: Spec
replySpec = describe "reply lowering" $ do
  let rc = ReplyContext (Just (NativeEventId "ev1")) (Just "李四") (Just "原文内容")
      rcNoNative = ReplyContext Nothing (Just "李四") (Just "原文内容")
      withReply tier ctx =
        lower baseEnv {caps = textOnlyCaps {reply = tier}, replyTarget = Just ctx} (Body [NText "说得对"])

  it "uses the native relation when a native copy exists" $ do
    let out = withReply TierNative rc
    out.replyNative `shouldBe` Just (NativeEventId "ev1")
    flat out `shouldBe` [NText "说得对"]
    out.notes `shouldBe` []

  it "falls back to a quote block when the native copy is missing" $ do
    let out = withReply TierNative rcNoNative
    out.replyNative `shouldBe` Nothing
    flat out `shouldBe` [NText "「李四: 原文内容」\n说得对"]
    out.notes `shouldBe` [LowerNote "reply" NoteFolded (Just "no native copy on endpoint")]

  it "quotes on the text tier and truncates long excerpts" $ do
    let long = T.replicate 80 "长"
        out = withReply TierText (ReplyContext (Just (NativeEventId "ev1")) (Just "李四") (Just long))
    flat out `shouldBe` [NText ("「李四: " <> T.replicate 59 "长" <> "…」\n说得对")]

  it "drops the relation silently when told to" $ do
    let out = withReply TierDrop rc
    out.replyNative `shouldBe` Nothing
    flat out `shouldBe` [NText "说得对"]
    out.notes `shouldBe` [LowerNote "reply" NoteDropped Nothing]

  it "records an unquotable reply instead of emitting an empty quote" $ do
    let out = withReply TierText (ReplyContext Nothing Nothing (Just "  "))
    flat out `shouldBe` [NText "说得对"]
    out.notes `shouldBe` [LowerNote "reply" NoteDropped (Just "no quotable context")]

  it "clears replyNative when nothing survives to send" $ do
    let env =
          baseEnv
            { caps = textOnlyCaps {reply = TierNative, mention = TierDrop},
              replyTarget = Just rc
            }
        out = lower env (Body [mentionNode])
    out.chunks `shouldBe` []
    out.replyNative `shouldBe` Nothing

chunkSpec :: Spec
chunkSpec = describe "chunking" $ do
  it "returns one chunk when no limit is declared" $ do
    let out = lower baseEnv (Body [NText (T.replicate 500 "a")])
    length out.chunks `shouldBe` 1

  it "splits oversized ASCII text and loses nothing" $ do
    let body = T.replicate 200 "a"
        out = lower baseEnv {caps = textOnlyCaps {maxTextBytes = Just 64}} (Body [NText body])
    length out.chunks `shouldBe` 4
    T.concat [t | c <- out.chunks, NText t <- c] `shouldBe` body
    for_ out.chunks $ \c -> chunkBytes c `shouldSatisfy` (<= 64)

  it "honours limits smaller than the old 64-byte floor" $ do
    let body = T.replicate 17 "a"
        out = lower baseEnv {caps = textOnlyCaps {maxTextBytes = Just 8}} (Body [NText body])
    fmap chunkBytes out.chunks `shouldBe` [8, 8, 1]

  it "never splits inside a multi-byte character" $ do
    let body = T.replicate 30 "汉"
        out = lower baseEnv {caps = textOnlyCaps {maxTextBytes = Just 64}} (Body [NText body])
    map (T.length . T.concat . map plainNode) out.chunks `shouldBe` [21, 9]
    T.concat [t | c <- out.chunks, NText t <- c] `shouldBe` body

  it "counts mention text against the budget" $ do
    let display = T.replicate 30 "n"
        env = baseEnv {caps = textOnlyCaps {mention = TierNative, maxTextBytes = Just 64}}
        out = lower env (Body [mention40 display, NText (T.replicate 60 "a")])
    length out.chunks `shouldBe` 2
  where
    plainNode = \case
      NText t -> t
      _ -> ""
    mention40 d = NMention (MentionIdentity knownIdentity) d

capsCodecSpec :: Spec
capsCodecSpec = describe "capability codec" $ do
  it "defaults to fail-closed text tiers on an empty manifest" $ do
    let caps = outboundCapsFromValue (object [])
    caps.text `shouldBe` False
    caps.mention `shouldBe` TierText
    caps.image `shouldBe` TierText
    caps.reaction `shouldBe` False
    caps.maxNativeMedia `shouldBe` 1

  it "does not interpret removed legacy capability booleans" $ do
    let caps =
          outboundCapsFromValue
            ( object
                [ "send_text" .= True,
                  "send_media" .= True,
                  "reply" .= True,
                  "max_text_bytes" .= (12000 :: Int)
                ]
            )
    caps.text `shouldBe` True
    caps.image `shouldBe` TierText
    caps.file `shouldBe` TierText
    caps.reply `shouldBe` TierText
    caps.maxTextBytes `shouldBe` Just 12000

  it "reads the v2 tier keys" $ do
    let caps = outboundCapsFromValue (object ["reply_tier" .= ("native" :: Text)])
    caps.reply `shouldBe` TierNative

  it "parses drop and treats junk tiers as text" $ do
    let caps =
          outboundCapsFromValue
            (object ["emote_tier" .= ("drop" :: Text), "mention_tier" .= ("holographic" :: Text)])
    caps.emote `shouldBe` TierDrop
    caps.mention `shouldBe` TierText

  it "fails closed on a malformed manifest" $
    outboundCapsFromValue (String "garbage") `shouldBe` noOutboundCaps

  it "round-trips through its own encoder" $ do
    let candidates =
          [ textOnlyCaps,
            noOutboundCaps,
            textOnlyCaps
              { mention = TierNative,
                reply = TierDrop,
                image = TierNative,
                emote = TierDrop,
                reaction = True,
                maxTextBytes = Just 4096,
                maxNativeMedia = 4
              }
          ]
    for_ candidates $ \caps ->
      outboundCapsFromValue (outboundCapsToValue caps) `shouldBe` caps

-- | The lowered output may contain a structural node only when its tier is
-- native. Keep this list exhaustive over every tier-governed constructor so
-- adding a capability cannot silently escape the shared lowerer.
invariantSpec :: Spec
invariantSpec = describe "lowering invariants" $ do
  it "drops text fallbacks when send_text is false while preserving native media" $ do
    let env =
          baseEnv
            { caps = noOutboundCaps {image = TierNative, maxNativeMedia = 1},
              mediaResolve = const (Just (ResolvedUrl "https://cdn.test/a.png"))
            }
        out = lower env (Body [NText "hidden", mentionNode, NMedia (Just (remote "https://x/a.png")) (mkMeta MImage Nothing)])
    flat out `shouldBe` [NMedia (ResolvedUrl "https://cdn.test/a.png") (mkMeta MImage Nothing)]
    map (.outcome) out.notes `shouldBe` [NoteDropped, NoteDropped]

  it "emits every tier-governed structure iff that exact tier is native" $ do
    for_ structuralCases $ \(label, envFor, node, isExpectedStructure, _) ->
      for_ [TierDrop, TierText, TierNative] $ \tier -> do
        let output = flat (lower (envFor tier) (Body [node]))
            survived = any isExpectedStructure output
        (label, tier, survived) `shouldBe` (label, tier, tier == TierNative)

  it "raising Drop → Text → Native never loses observable content" $ do
    for_ structuralCases $ \(label, envFor, node, _, evidence) -> do
      let observable tier =
            evidence `T.isInfixOf` T.concat (map loweredEvidence (flat (lower (envFor tier) (Body [node]))))
      (label, map observable [TierDrop, TierText, TierNative])
        `shouldBe` (label, [False, True, True])

  it "raising the reply tier never loses reply provenance" $ do
    let replyContext = ReplyContext (Just (NativeEventId "reply-event")) (Just "李四") (Just "原文")
        observable tier =
          let output = lower baseEnv {caps = textOnlyCaps {reply = tier}, replyTarget = Just replyContext} (Body [NText "回复"])
              wireText = T.concat [body | NText body <- flat output]
           in isJust output.replyNative || "李四: 原文" `T.isInfixOf` wireText
    map observable [TierDrop, TierText, TierNative] `shouldBe` [False, True, True]

structuralCases :: [(String, Tier -> LowerEnv, Node 'Canonical, Node 'Lowered -> Bool, Text)]
structuralCases =
  [ ("mention", withMention, mentionNode, \case NMention {} -> True; _ -> False, "张三"),
    ("emote", withEmote, NEmote qqFace, \case NEmote {} -> True; _ -> False, "惊讶"),
    mediaCase "image" MImage (\tier caps -> caps {image = tier}),
    mediaCase "sticker" MSticker (\tier caps -> caps {sticker = tier}),
    mediaCase "video" MVideo (\tier caps -> caps {video = tier}),
    mediaCase "audio" MAudio (\tier caps -> caps {audio = tier}),
    mediaCase "file" MFile (\tier caps -> caps {file = tier}),
    ( "card",
      \tier -> baseEnv {caps = textOnlyCaps {card = tier}},
      NCard (Card (Just "标题") Nothing Nothing Nothing Nothing (Just (String "wire"))),
      \case NCard {} -> True; _ -> False,
      "标题"
    )
  ]
  where
    withMention tier = baseEnv {caps = textOnlyCaps {mention = tier}}
    withEmote tier = baseEnv {platform = PlatformQQ, caps = textOnlyCaps {emote = tier}}
    mediaCase label kind setTier =
      ( label,
        \tier -> baseEnv {caps = setTier tier textOnlyCaps {maxNativeMedia = 1}},
        NMedia (Just (remote ("https://x/" <> T.pack label))) (mkMeta kind (Just (T.pack label))),
        \case NMedia {} -> True; _ -> False,
        T.pack label
      )

loweredEvidence :: Node 'Lowered -> Text
loweredEvidence = \case
  NText body -> body
  NMention _ display -> display
  NEmote emote -> fromMaybe emote.nativeId emote.name
  NMedia _ meta -> fromMaybe (mediaKindText meta.kind) meta.description
  NCard card -> fromMaybe "card" card.title
