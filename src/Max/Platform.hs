-- |
-- Multi-platform backend abstraction (0.4).  max's internal lingua
-- franca stays the OneBot model — 'OneBot.Segment.Segment' as the
-- message IR, 'OneBot.Action.Action' as the outbound op set, bigint
-- ids everywhere — and a platform backend is just a translator on
-- the two existing seams:
--
--   * inbound: the adapter parses platform traffic into 'OneBot.Event'
--     values and writes them to the shared event queue (nothing to
--     abstract — the queue already decouples sources);
--   * outbound: every send goes through "Max.Effects.NapCat"'s
--     effect, whose interpreter routes each 'Action' to the backend
--     that owns the target id.
--
-- Foreign platforms (WeChat, Telegram, …) have string-typed native
-- ids; the @platform_ids@ table ("Max.DB.PlatformIds") maps them
-- into a reserved bigint range at or below 'foreignIdBase', so the
-- whole existing pipeline (DB, prompt, permissions) works untouched
-- and routing is a pure range check.  Capability gaps (no reactions
-- on WeChat, no reply segments) are the backend's own business: it
-- degrades or no-ops inside 'pbSend' and the caller never knows.
module Max.Platform
  ( PlatformBackend (..),
    routeAction,
    actionTargetId,
    foreignIdBase,
    isForeignId,
  )
where

import Data.Int (Int64)
import Data.Text (Text)
import OneBot.Action (Action (..), Response)
import OneBot.Types (GroupId (..), MessageId (..), UserId (..))

-- | One chat platform's outbound half.  'pbOwnsId' claims the
-- synthetic id ranges this backend is responsible for; the QQ
-- backend is the router's default and never needs to claim anything.
data PlatformBackend = PlatformBackend
  { pbName :: !Text,
    pbOwnsId :: !(Int64 -> Bool),
    -- | Fire-and-forget send.  'Left' is logged by the interpreter.
    pbSend :: !(Action -> IO (Either Text ())),
    -- | Send and await a response, with a millisecond budget.
    pbCall :: !(Action -> Int -> IO (Either Text Response))
  }

-- | Synthetic ids for non-QQ platforms are allocated at or below
-- this base (see migration 025).  Real QQ ids (positive, < 2^40ish)
-- and private-chat pseudo groups (their negations) never reach it.
foreignIdBase :: Int64
foreignIdBase = -1_000_000_000_000

-- | Does this id live in the foreign (mapped) range?  Covers both a
-- mapped id itself and its negation (a foreign private-chat pseudo
-- group is @negate mappedUserId@, which is a huge positive).
isForeignId :: Int64 -> Bool
isForeignId i = i <= foreignIdBase || i >= negate foreignIdBase

-- | The id an action is addressed to, for routing.  Actions with no
-- target (none today) would fall to the default backend.
actionTargetId :: Action -> Maybe Int64
actionTargetId = \case
  SendGroupMsg (GroupId g) _ -> Just g
  SendPrivateMsg (UserId u) _ -> Just u
  GetForwardMsg _ -> Nothing
  GetGroupFileUrl (GroupId g) _ -> Just g
  UploadGroupFile (GroupId g) _ _ -> Just g
  UploadPrivateFile (UserId u) _ _ -> Just u
  GetGroupMemberList (GroupId g) -> Just g
  GetGroupInfo (GroupId g) -> Just g
  SetMsgEmojiLike (MessageId m) _ _ -> Just m
  SendPoke (GroupId g) _ -> Just g
  SetFriendAddRequest _ _ -> Nothing

-- | Pick the backend for an action: first extra backend that claims
-- the target id, else the default.
routeAction :: [PlatformBackend] -> PlatformBackend -> Action -> PlatformBackend
routeAction extras dflt a = case actionTargetId a of
  Nothing -> dflt
  Just target ->
    case [b | b <- extras, b.pbOwnsId target] of
      (b : _) -> b
      [] -> dflt
