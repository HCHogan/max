{-# LANGUAGE OverloadedStrings #-}

-- | The two invariants ADR 003's five consumers share, stated as laws.
--
-- They are the comonad laws, transplanted.  A comonad is "a value together
-- with the context it sits in": @extract@ reads the value at the focus and
-- @duplicate@ replaces every position with that position's whole context.
-- Two of its laws say something max needs and never wrote down:
--
-- * @extract . duplicate = id@ — annotating does not move the focus.  Here:
--   projecting a body out to text and reading it back returns the same body.
--   Tested on the model-facing phase, which is the only one with an inverse.
--
-- * @fmap extract . duplicate = id@ — every position keeps its own identity.
--   Here: a projection may drop content, but a node that carries a canonical
--   identity must still name /that/ identity, in /that/ position, on the far
--   side.  Tested on the stored phase, where there is no inverse and content
--   genuinely is dropped — a card flattens, a forward becomes a marker, a
--   blob reference disappears — so identity preservation is the whole of what
--   survives, and is exactly ADR 004's claim that the model reads back the
--   handle vocabulary it writes.
--
-- Neither law is a new requirement.  Both were load-bearing already and
-- checked only by example: 'Max.IR.PromptSpec' pins nine round trips by hand.
-- The corpus below enumerates every sequence of token atoms up to length
-- three, so adjacency, merging and trimming are covered by construction
-- rather than by whichever cases somebody thought of.
module Max.IR.LawSpec (spec) where

import Data.Aeson (Value, object, (.=))
import Data.Foldable (for_)
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as T
import Max.IR
import Max.IR.Prompt (emitModelChunk, parseModelChunk, promptCanonicalText, MentionRoster (..))
import Max.Platform.Types (CanonicalMessageId (..), Platform (..), PrincipalId (..), PrincipalIdentityId (..))
import Test.Hspec

spec :: Spec
spec = do
  focusLaw
  identityLaw

-- | The roster names one display so @\@张三@ rescue is exercised, and
-- deliberately has no self principal: 'parseModelChunk' drops a mention of
-- the bot itself on purpose, which would read as a law violation while being
-- the documented behaviour.  Self-mention dropping is 'Max.IR.PromptSpec's.
roster :: MentionRoster
roster = MentionRoster {names = [("张三", PrincipalId 123)], selfPrincipal = Nothing}

-- ---------------------------------------------------------------------------
-- extract . duplicate = id
-- ---------------------------------------------------------------------------

-- | Every token the model may author, plus the text that surrounds them.
-- Sequences of these are what the parser can actually reach, which is the
-- domain the law is stated over — an arbitrary 'Body' is not, because two
-- adjacent 'NText' nodes are a shape the parser never produces.
atoms :: [Text]
atoms =
  [ "文字",
    "plain",
    "@张三",
    "[mention#123]",
    "[mention#987]",
    "[sticker#42]",
    "[sticker#柴犬瘫地]",
    "[image#7407]",
    "[image#7407.2]",
    "[face#5]",
    "[not a token]",
    "a@123456.com",
    -- Adversarial: near-misses and malformed openers.  A marker that lost its
    -- closing bracket reached a real group three days ago (0cd74bb), so the
    -- shape belongs in the domain rather than outside it — whatever the
    -- parser decides these mean, emitting and re-reading must not change it.
    "[sticker#柴犬瘫地: 说明]",
    "[image#7407.0]",
    "[mention#123",
    "[mention#]",
    "[",
    "]"
  ]

-- | All sequences of length 1..3, space-joined, plus the same sequences with
-- no separator so that adjacency is covered too.
corpus :: [Text]
corpus =
  [ joiner pieces
  | n <- [1 .. 3 :: Int],
    pieces <- sequencesOf n,
    joiner <- [T.unwords, T.concat]
  ]
  where
    sequencesOf 0 = [[]]
    sequencesOf n = [a : rest | a <- atoms, rest <- sequencesOf (n - 1)]

-- | The reply token leads a chunk and is carried beside the body, so the law
-- has to hold for each of its inhabitants too.
replyTargets :: [Maybe Int64]
replyTargets = [Nothing, Just 98765, Just (-42)]

focusLaw :: Spec
focusLaw = describe "extract . duplicate = id (projection preserves content)" $
  it "parse . emit is the identity on every parser-reachable body" $
    for_ corpus $ \source ->
      for_ replyTargets $ \target -> do
        let (_, body) = parseModelChunk roster source
            emitted = emitModelChunk target body
            -- Reported with the source text so a failure names the input
            -- that produced the body rather than only the body.
            label = (source, target)
        (label, parseModelChunk roster emitted) `shouldBe` (label, (target, body))

-- ---------------------------------------------------------------------------
-- fmap extract . duplicate = id
-- ---------------------------------------------------------------------------

-- | What a node names, as opposed to what it says.  Text, cards, forwards and
-- unsupported nodes name nothing and are exempt: the law constrains positions
-- that carry an identity, and says nothing about positions that do not.
data Ident
  = IdMention !Int64
  | IdSticker !Int64
  | IdStickerDesc !Text
  | IdImage !Int64 !(Maybe Int)
  | IdFace !Text
  deriving stock (Eq, Show)

identsOf :: Body 'ModelParsed -> [Ident]
identsOf body = concatMap node body.nodes
  where
    node = \case
      NMention (PrincipalId principal) _ -> [IdMention principal]
      NMedia (RefSticker sid) _ -> [IdSticker sid]
      NMedia (RefStickerDesc d) _ -> [IdStickerDesc d]
      NMedia (RefImage (CanonicalMessageId cid) seg) _ -> [IdImage cid seg]
      NEmote e -> [IdFace e.nativeId]
      NText _ -> []
      NCard _ -> []

-- | A stored node beside the identity it must still name after projection.
-- The expectation is written out rather than derived: deriving it would
-- re-implement the renderer inside its own test, and the claim under test is
-- precisely that two independently written sides — 'promptCanonicalText' and
-- 'parseModelChunk' — agree on one vocabulary.
canonicalAtoms :: [(Node 'Canonical, [Ident])]
canonicalAtoms =
  [ (NText "文字", []),
    (NMention (MentionIdentity (PrincipalIdentityId 11)) "张三", [IdMention 123]),
    -- Unresolvable identity degrades to @name and names nobody; the law is
    -- satisfied by naming nothing rather than by inventing a handle.
    (NMention (MentionIdentity (PrincipalIdentityId 99)) "李四", []),
    (NMention MentionAll "全体成员", []),
    (NEmote (emote "5" Nothing), [IdFace "5"]),
    (NEmote (emote "212" (Just "托腮")), [IdFace "212"]),
    (NMedia Nothing (stickerMeta 42 (Just "柴犬瘫地")), [IdSticker 42]),
    (NMedia Nothing (imageMeta 7407 (Just 2)), [IdImage 7407 (Just 2)]),
    (NMedia Nothing (imageMeta 7407 Nothing), [IdImage 7407 Nothing]),
    -- Inbound media with no stored handle: the id it would name is assigned
    -- by the insert that stores this very text, so there is nothing yet.
    (NMedia Nothing bareImageMeta, []),
    (NCard card, []),
    (NForward (ForwardRef {nativeId = "abc", count = Just 3}), []),
    (NUnsupported (Unsupported {source = "qq", description = "语音消息", raw = Nothing}), [])
  ]
  where
    emote nativeId name = Emote {origin = PlatformQQ, nativeId, name, raw = Nothing}
    meta kind description raw =
      MediaMeta {kind, mime = Nothing, sizeBytes = Nothing, name = Nothing, description, raw}
    stickerMeta sid description =
      meta MSticker description (Just (object ["sticker_id" .= (sid :: Int64)]))
    imageMeta cid seg = meta MImage Nothing (Just (imageRaw cid seg))
    bareImageMeta = meta MImage Nothing Nothing
    card =
      Card
        { title = Just "标题",
          subtitle = Nothing,
          url = Just "https://example.com",
          tag = Just "分享",
          preview = Nothing,
          raw = Nothing
        }

imageRaw :: Int64 -> Maybe Int -> Value
imageRaw cid = \case
  Nothing -> object ["source_message_id" .= cid]
  Just seg -> object ["source_message_id" .= cid, "source_seg_index" .= seg]

-- | The one always-defined join a canonical projection takes: identity →
-- principal.  Identity 99 is deliberately absent.
principals :: Map.Map PrincipalIdentityId PrincipalId
principals = Map.fromList [(PrincipalIdentityId 11, PrincipalId 123)]

identityLaw :: Spec
identityLaw = describe "fmap extract . duplicate = id (projection preserves identity)" $
  it "every stored identity survives the prompt projection, in order" $
    for_ canonicalCorpus $ \(body, expected) -> do
      let projected = promptCanonicalText principals body
          (_, reparsed) = parseModelChunk roster projected
      (projected, identsOf reparsed) `shouldBe` (projected, expected)
  where
    canonicalCorpus =
      [ (Body (map fst picked), concatMap snd picked)
      | n <- [1 .. 3 :: Int],
        picked <- sequencesOf n
      ]
    sequencesOf 0 = [[]]
    sequencesOf n = [a : rest | a <- canonicalAtoms, rest <- sequencesOf (n - 1)]
