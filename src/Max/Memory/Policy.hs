-- | Pure admission and content policy shared by explicit tools and Historian.
module Max.Memory.Policy
  ( MemorySubject (..),
    DuplicatePolicy (..),
    MemoryAdmissionFailure (..),
    MemoryWriteFailure (..),
    maxMemoriesPerScope,
    maxMemoryChars,
    checkContent,
    memoryWriteFailureText,
  )
where

import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as T

-- | Nothing denotes the caller's principal, resolved only by the interpreter.
data MemorySubject = ConversationMemory | PersonMemory !(Maybe Int64) deriving stock (Eq, Show)

data DuplicatePolicy = AllowDuplicates | RejectExactDuplicates deriving stock (Eq, Show)

data MemoryAdmissionFailure = MemoryAtCapacity | ExactMemoryAlreadyExists | MemoryConversationMissing deriving stock (Eq, Show)

data MemoryWriteFailure
  = MemoryCallerFenced
  | MemoryNotWritable
  | MemoryContentInvalid !Text
  | MemoryAdmissionRejected !MemoryAdmissionFailure
  deriving stock (Eq, Show)

-- | Per (scope, scope_id) ceiling.  Hitting it turns 'memory_save'
-- into an error that demands consolidation first — the pressure that
-- keeps the block small enough to inject wholesale.
maxMemoriesPerScope :: Int
maxMemoriesPerScope = 30

-- | One memory is a compact fact, not an essay.
maxMemoryChars :: Int
maxMemoryChars = 300

checkContent :: Text -> Either Text Text
checkContent raw
  | T.null c = Left "content 不能为空"
  | T.length c > maxMemoryChars =
      Left ("content 太长（" <> tshow (T.length c) <> " 字），压缩到 " <> tshow maxMemoryChars <> " 字以内")
  | otherwise = Right c
  where
    c = T.strip raw

tshow :: (Show a) => a -> Text
tshow = T.pack . show

memoryWriteFailureText :: MemoryWriteFailure -> Text
memoryWriteFailureText = \case
  MemoryCallerFenced -> "当前回合身份、来源或执行租约已失效，不能修改记忆"
  MemoryNotWritable -> "记忆不存在、不可见，或版本已变化；请重新 memory_list 后再试"
  MemoryContentInvalid detail -> detail
  MemoryAdmissionRejected MemoryAtCapacity -> "该 scope 的记忆已满（" <> tshow maxMemoriesPerScope <> " 条）。先用 memory_forget 删掉过时的，或用 memory_update 合并相近条目，再保存。"
  MemoryAdmissionRejected ExactMemoryAlreadyExists -> "已经存在相同记忆"
  MemoryAdmissionRejected MemoryConversationMissing -> "记忆所属会话已不可用"
