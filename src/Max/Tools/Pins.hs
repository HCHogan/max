-- |
-- Agent-side pin management.  @!pin@/@!unpin@ exist as user commands,
-- but in practice nobody does prospective bookkeeping in a chat — so
-- the model gets the same mutators as tools and curates the pin list
-- itself: pin the spec message it keeps re-searching for, unpin what
-- stopped being relevant.  Silent by design (no group message); the
-- result shows up as the [pinned] block of the next prompt.
module Max.Tools.Pins
  ( pinToolsFor,
  )
where

import Data.Aeson
import Data.Aeson.Types (Parser, parseEither)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T
import Effectful
import Effectful.Log
import Effectful.PostgreSQL (WithConnection)
import Max.ConversationScope (conversationScopeFor)
import Max.DB.History (fetchMessageInScope)
import Max.Effects.Tools (Tool (..))
import Max.Session (Session (..), SessionRegistry, loadSession, updateSession)
import Max.Session qualified as Session
import Max.ToolContext (ToolContext, toolGroupId)

pinToolsFor ::
  (WithConnection :> es, Log :> es, IOE :> es) =>
  SessionRegistry ->
  Text -> -- default model name (for 'loadSession')
  ToolContext ->
  [Tool es]
pinToolsFor sessions defaultModel dc =
  [ pinTool sessions defaultModel dc,
    unpinTool sessions defaultModel dc
  ]

-- | Cap on how many pins the *model* may accumulate.  The user's
-- @!pin@ is uncapped (they can see and manage the list); an autonomous
-- pinner needs a backstop so the block can't silently eat the prompt.
maxToolPins :: Int
maxToolPins = 12

pinTool ::
  (WithConnection :> es, Log :> es, IOE :> es) =>
  SessionRegistry ->
  Text ->
  ToolContext ->
  Tool es
pinTool sessions defaultModel dc =
  Tool
    { toolName = "pin_message",
      toolDescription =
        T.unwords
          [ "把一条消息固定进长期上下文：之后每次对话都会看到它（[pinned] 区块，!clear 也不清）。",
            "适合以后还会反复用到的东西——需求/规格、关键决定、要长期参考的图片消息。",
            "典型信号：你发现自己在为同一条消息翻历史。宁缺毋滥，一次性的内容不要 pin。",
            "不需要请示用户，直接 pin 即可。"
          ],
      toolSchema =
        object
          [ "type" .= ("object" :: Text),
            "properties"
              .= object
                [ "message_id"
                    .= object
                      [ "type" .= ("integer" :: Text),
                        "description" .= ("要固定的消息 id（上下文行里的 #<id>）" :: Text)
                      ]
                ],
            "required" .= (["message_id"] :: [Text])
          ],
      toolRun = \args -> case parseEither (withObject "args" parseMessageId) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right mid ->
          fetchMessageInScope (conversationScopeFor (toolGroupId dc)) mid >>= \case
            Nothing -> pure $ Left ("找不到 message_id=" <> tshow mid)
            Just _ -> do
              t <- loadSession sessions defaultModel (toolGroupId dc)
              res <- updateSession t $ \s ->
                if length s.pinned >= maxToolPins && mid `notElem` s.pinned
                  then (s, Left (length s.pinned))
                  else let s' = Session.addPin mid s in (s', Right (length s'.pinned))
              case res of
                Left n ->
                  pure $
                    Left
                      ( "pin 已达上限（"
                          <> tshow n
                          <> " 条）；先用 unpin_message 清掉不再需要的"
                      )
                Right n -> do
                  logInfo "pin tool: pinned" $
                    object ["message_id" .= mid, "pin_count" .= n]
                  pure $ Right (object ["ok" .= True, "pin_count" .= n])
    }

unpinTool ::
  (WithConnection :> es, Log :> es, IOE :> es) =>
  SessionRegistry ->
  Text ->
  ToolContext ->
  Tool es
unpinTool sessions defaultModel dc =
  Tool
    { toolName = "unpin_message",
      toolDescription =
        T.unwords
          [ "把一条不再需要长期保留的消息移出 [pinned]。",
            "看到里面有过时、已解决或不再相关的内容时，主动清理。"
          ],
      toolSchema =
        object
          [ "type" .= ("object" :: Text),
            "properties"
              .= object
                [ "message_id"
                    .= object
                      [ "type" .= ("integer" :: Text),
                        "description" .= ("要移除的消息 id（[pinned] 行里的 #<id>）" :: Text)
                      ]
                ],
            "required" .= (["message_id"] :: [Text])
          ],
      toolRun = \args -> case parseEither (withObject "args" parseMessageId) args of
        Left e -> pure $ Left ("bad args: " <> T.pack e)
        Right mid -> do
          t <- loadSession sessions defaultModel (toolGroupId dc)
          removed <- updateSession t $ \s ->
            if mid `elem` s.pinned
              then (Session.removePin mid s, True)
              else (s, False)
          if removed
            then do
              logInfo "pin tool: unpinned" $ object ["message_id" .= mid]
              pure $ Right (object ["ok" .= True])
            else pure $ Left ("message_id=" <> tshow mid <> " 不在 pin 列表里")
    }

parseMessageId :: Object -> Parser Int64
parseMessageId o = o .: "message_id"

tshow :: (Show a) => a -> Text
tshow = T.pack . show
