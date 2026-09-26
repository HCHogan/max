-- | Host-owned attachments travel with the invocation that produced them.
module Max.Tool.Media (InlineMedia (..), inlineMediaMessages) where

import Data.Text (Text)
import Data.Text qualified as T
import Max.LLM.Types (ChatMessage (MsgUserBlocks), ContentBlock (..))

data InlineMedia = InlineMedia
  { imLabel :: !Text,
    imDataUrl :: !Text,
    -- | Prepared video vision tokens; images retain their encoded dimensions.
    imVisionTokens :: !(Maybe Int)
  }
  deriving stock (Show, Eq)

inlineMediaMessages :: [InlineMedia] -> [ChatMessage]
inlineMediaMessages media = [MsgUserBlocks (concatMap blocks media) | not (null media)]
  where
    blocks item = [TextBlock item.imLabel, content item]
    content item
      | "data:video/" `T.isPrefixOf` item.imDataUrl = VideoDataUrl item.imDataUrl item.imVisionTokens
      | otherwise = ImageDataUrl item.imDataUrl
