-- | Pure policy for learning group lingo, after MaiBot's expression and jargon
-- learners: what the model is shown, which of its answers are accepted, when
-- a term's meaning is (re)inferred, and what one prompt samples back.
module Max.Lingo.Policy
  ( -- * Learning input
    LingoSource (..),
    lingoLearnerSystem,
    renderLingoSources,
    cleanLingoLine,

    -- * Learning output
    RawExpression (..),
    RawJargon (..),
    LearnedBatch (..),
    parseLearnedBatch,
    ExpressionObservation (..),
    JargonObservation (..),
    acceptExpressions,
    acceptJargon,
    styleKey,
    termKey,

    -- * Meaning inference
    jargonInferenceThresholds,
    needsInference,
    generalMeaningPrompt,
    parseGeneralMeaning,
    contextualMeaningPrompt,
    JargonInference (..),
    parseContextualMeaning,

    -- * Prompt-time selection
    promptExpressionPool,
    promptExpressionSample,
    promptJargonPool,
    promptJargonMatches,
    promptJargonWindow,
    sampleExpressions,
    matchJargon,
  )
where

import Control.Applicative (optional)
import Control.Monad (guard)
import Data.Aeson (FromJSON (..), Value (..), eitherDecodeStrict', withObject, (.!=), (.:?))
import Data.Aeson.Types (Parser)
import Data.Bits (shiftR, xor)
import Data.Char (isAlphaNum, isAscii, isPunctuation, isSpace, isSymbol)
import Data.Int (Int64)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (listToMaybe, mapMaybe)
import Data.Ord (Down (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word64)
import Max.Lingo.Types

-- | One transcript line the learner may cite by its 1-based 'lsIndex'.
data LingoSource = LingoSource
  { lsIndex :: !Int,
    lsMessageId :: !Int64,
    lsPrincipal :: !Int64,
    lsName :: !Text,
    lsFromBot :: !Bool,
    lsText :: !Text
  }
  deriving stock (Show, Eq)

lingoLearnerSystem :: Text
lingoLearnerSystem =
  T.intercalate
    "\n"
    [ "你在帮群聊里的「Max」学习这个群的说话方式。下面是一段按时间排列的聊天记录，每行开头的 [数字] 是来源编号。",
      "标着「Max（你自己）」的是 Max 自己的发言，只当上下文看，不要从中学习。",
      "",
      "任务一：总结群友的说话习惯（expressions）。",
      "- 只看文字，不考虑表情包和图片；不要涉及具体人名，也不要涉及具体名词。",
      "- 写成「当 situation 时，可以 style」：situation 概括场景，不超过 20 个字；style 是对应的句式、说法或语气，不超过 20 个字。",
      "- 群里特有的梗、固定说法、口头禅也总结进来。",
      "- 一般 3 到 5 条，最多 10 条；没有明显的习惯就少写，宁缺毋滥。",
      "",
      "任务二：找出可能是黑话的词（jargon）。",
      "- 必须是记录里真实出现过的短词或短语，照原样抄下来，一般 2 到 8 个字。",
      "- 只要需要这个群的语境才能懂、或者你拿不准意思的：拼音首字母缩写（如 nb、xswl）、中文缩写、群里反复出现的梗和口头禅。",
      "- 不要：人名和群昵称、@、表情包和图片里的内容、纯标点、意思清楚的普通词。",
      "- 最多 15 个。",
      "",
      "只输出一个 JSON 对象，不要任何其他内容：",
      "{\"expressions\": [{\"situation\": \"对某件事表示十分惊叹\", \"style\": \"用 我嘞个xxx\", \"source_id\": 3}, {\"situation\": \"表示讽刺的赞同\", \"style\": \"用 对对对\", \"source_id\": 4}], \"jargon\": [{\"term\": \"典\", \"source_id\": 5}]}",
      "source_id 填这一条所依据的那行开头的来源编号数字。例子只示范格式，内容要严格根据这段聊天记录。"
    ]

-- | Numbered transcript for the learner.  Newlines inside a message become
-- a visible marker so one source id is always one line.
renderLingoSources :: [LingoSource] -> Text
renderLingoSources sources =
  T.intercalate "\n" $
    ["聊天记录："]
      <> [ "[" <> T.pack (show source.lsIndex) <> "] " <> speaker source <> "：" <> T.take 200 (T.replace "\n" " ⏎ " source.lsText)
         | source <- sources
         ]
      <> ["", "输出 JSON："]
  where
    speaker source
      | source.lsFromBot = "Max（你自己）"
      | otherwise = source.lsName

-- | Platform markers ([image#…], [sticker#…], [reply#…]) are not speech, and
-- links are not vocabulary.  What remains is the member's own wording.
cleanLingoLine :: Text -> Text
cleanLingoLine = T.unwords . filter (not . isLink) . T.words . stripMarkers
  where
    isLink word = any (`T.isPrefixOf` T.toLower word) ["http://", "https://", "www."]

stripMarkers :: Text -> Text
stripMarkers text = case T.breakOn "[" text of
  (before, rest)
    | T.null rest -> before
    | otherwise -> case T.breakOn "]" rest of
        (_, closing)
          | T.null closing -> before <> rest
          | otherwise -> before <> " " <> stripMarkers (T.drop 1 closing)

data RawExpression = RawExpression
  { reSituation :: !Text,
    reStyle :: !Text,
    reSource :: !(Maybe Int)
  }
  deriving stock (Show, Eq)

data RawJargon = RawJargon
  { rjTerm :: !Text,
    rjSource :: !(Maybe Int)
  }
  deriving stock (Show, Eq)

data LearnedBatch = LearnedBatch
  { lbExpressions :: ![RawExpression],
    lbJargon :: ![RawJargon]
  }
  deriving stock (Show, Eq)

instance FromJSON LearnedBatch where
  parseJSON = withObject "LearnedBatch" $ \o ->
    LearnedBatch
      <$> (o .:? "expressions" .!= [])
      <*> (o .:? "jargon" .!= [])

instance FromJSON RawExpression where
  parseJSON = withObject "expression" $ \o ->
    RawExpression
      <$> (o .:? "situation" .!= "")
      <*> (o .:? "style" .!= "")
      <*> (sourceId =<< (o .:? "source_id" .!= Null))

instance FromJSON RawJargon where
  parseJSON = withObject "jargon" $ \o ->
    RawJargon
      <$> (o .:? "term" .!= "")
      <*> (sourceId =<< (o .:? "source_id" .!= Null))

-- | Models quote numbers often enough that a string id is still an id.
sourceId :: Value -> Parser (Maybe Int)
sourceId = \case
  number@(Number _) -> optional (parseJSON number)
  String s -> pure (readInt (T.strip s))
  _ -> pure Nothing
  where
    readInt s = case reads (T.unpack s) of
      [(n, "")] -> Just n
      _ -> Nothing

-- | Everything outside the outermost object is ignored, so fences and a stray
-- sentence around the JSON do not lose the batch.
parseLearnedBatch :: Text -> Either String LearnedBatch
parseLearnedBatch raw = do
  object' <- maybe (Left "no JSON object in response") Right (outermostObject raw)
  eitherDecodeStrict' (TE.encodeUtf8 object')

outermostObject :: Text -> Maybe Text
outermostObject text =
  let afterOpen = T.dropWhile (/= '{') text
      object' = T.dropWhileEnd (/= '}') afterOpen
   in if T.null object' then Nothing else Just object'

-- | An expression the batch supports, ready to merge into the store.
data ExpressionObservation = ExpressionObservation
  { eoSituation :: !Text,
    eoStyle :: !Text,
    eoStyleKey :: !Text,
    eoMessageId :: !Int64,
    eoExample :: !Text
  }
  deriving stock (Show, Eq)

-- | A jargon candidate together with who said it and the lines around it.
data JargonObservation = JargonObservation
  { joTerm :: !Text,
    joTermKey :: !Text,
    joMessageId :: !Int64,
    joPrincipal :: !Int64,
    joExample :: !Text,
    joContext :: !Text
  }
  deriving stock (Show, Eq)

maxExpressionsPerBatch, maxJargonPerBatch, maxPhraseLength, maxTermLength :: Int
maxExpressionsPerBatch = 10
maxJargonPerBatch = 15
maxPhraseLength = 40
maxTermLength = 16

-- | Keep only expressions a member (not Max) demonstrably used, with a
-- non-empty spoken example; the first occurrence of each style wins.
acceptExpressions :: [LingoSource] -> [RawExpression] -> [ExpressionObservation]
acceptExpressions sources raws =
  take maxExpressionsPerBatch . dedupOn (.eoStyleKey) $ mapMaybe accept raws
  where
    byIndex = Map.fromList [(source.lsIndex, source) | source <- sources]
    accept raw = do
      source <- (`Map.lookup` byIndex) =<< raw.reSource
      guard (not source.lsFromBot)
      let situation = T.strip raw.reSituation
          style = T.strip raw.reStyle
          example = T.take 80 (cleanLingoLine source.lsText)
          key = styleKey style
      guard (phrase situation && phrase style && not (T.null key) && not (T.null example))
      guard (T.toCaseFold style `notElem` ["max", "max（你自己）"])
      pure (ExpressionObservation situation style key source.lsMessageId example)
    phrase text = not (T.null text) && T.length text <= maxPhraseLength && not (T.any (`elem` ['[', ']']) text)

-- | Keep only terms that literally occur in a member's own words (outside
-- links and platform markers) and are not somebody's name.
acceptJargon :: [LingoSource] -> [RawJargon] -> [JargonObservation]
acceptJargon sources raws =
  take maxJargonPerBatch . dedupOn (.joTermKey) $ mapMaybe accept raws
  where
    indexed = zip [0 :: Int ..] sources
    byIndex = Map.fromList [(source.lsIndex, (position, source)) | (position, source) <- indexed]
    names = Set.fromList [termKey source.lsName | source <- sources, not (T.null (termKey source.lsName))]
    accept raw = do
      (position, source) <- (`Map.lookup` byIndex) =<< raw.rjSource
      guard (not source.lsFromBot)
      let term = T.strip (T.dropAround (`elem` quotes) (T.strip raw.rjTerm))
          key = termKey term
          spoken = cleanLingoLine source.lsText
      guard (not (T.null key) && T.length term <= maxTermLength)
      guard (T.any isAlphaNum term)
      guard (key `Set.notMember` names && not (isNameFragment key))
      guard (occursIn key (T.toCaseFold spoken))
      let previous = [contextLine s | (p, s) <- indexed, p == position - 1]
      pure
        JargonObservation
          { joTerm = term,
            joTermKey = key,
            joMessageId = source.lsMessageId,
            joPrincipal = source.lsPrincipal,
            joExample = T.take 80 spoken,
            joContext = T.intercalate "\n" (previous <> [contextLine source])
          }
    quotes = "\"'「」『』“”‘’《》" :: String
    contextLine source = T.take 120 ((if source.lsFromBot then "Max" else source.lsName) <> "：" <> cleanLingoLine source.lsText)
    -- A term that is only part of one member's name is most likely that name.
    isNameFragment key = any (\name -> key `T.isInfixOf` name && T.length key * 2 >= T.length name) (Set.toList names)

-- | Same style with different spacing, case or wrapping quotes is one habit.
styleKey :: Text -> Text
styleKey = T.filter (\c -> not (isSpace c) && c `notElem` ("\"'「」『』“”‘’" :: String)) . T.toCaseFold

termKey :: Text -> Text
termKey = T.filter (not . isSpace) . T.toCaseFold

dedupOn :: (Ord k) => (a -> k) -> [a] -> [a]
dedupOn key = go Set.empty
  where
    go _ [] = []
    go seen (x : xs)
      | key x `Set.member` seen = go seen xs
      | otherwise = x : go (Set.insert (key x) seen) xs

-- | A latin or numeric term must stand alone (\"ds\" is not in \"friends\");
-- CJK terms have no word boundary to require.
occursIn :: Text -> Text -> Bool
occursIn key haystack = any bounded (T.breakOnAll key haystack)
  where
    latin = T.all (\c -> isAscii c && isAlphaNum c) key
    bounded (before, after)
      | not latin = True
      | otherwise =
          not (maybe False (isWordChar . snd) (T.unsnoc before))
            && not (maybe False (isWordChar . fst) (T.uncons (T.drop (T.length key) after)))
    isWordChar c = isAscii c && isAlphaNum c

-- | MaiBot's thresholds: meaning is inferred when a term's batch count first
-- reaches each of these, and never for a term only one member has used.
jargonInferenceThresholds :: [Int]
jargonInferenceThresholds = [4, 8, 25, 100]

needsInference :: Int -> Int -> Int -> Bool
needsInference hits inferredHits speakers =
  speakers >= 2 && any (\threshold -> threshold > inferredHits && threshold <= hits) jargonInferenceThresholds

-- | The context-free reading, asked without any of the group's lines so the
-- comparison below measures what the group adds.
generalMeaningPrompt :: Text -> Text
generalMeaningPrompt term =
  T.intercalate
    "\n"
    [ "词条：「" <> term <> "」",
      "不看任何上下文，只凭你对中文互联网的了解，说说这个词一般是什么意思。不知道就直说不知道。",
      "只输出 JSON：{\"meaning\": \"不超过 60 字\"}"
    ]

parseGeneralMeaning :: Text -> Maybe Text
parseGeneralMeaning raw = do
  object' <- outermostObject raw
  MeaningOnly meaning <- either (const Nothing) Just (eitherDecodeStrict' (TE.encodeUtf8 object'))
  let trimmed = T.strip meaning
  if T.null trimmed then Nothing else Just trimmed

newtype MeaningOnly = MeaningOnly Text

instance FromJSON MeaningOnly where
  parseJSON = withObject "meaning" $ \o -> MeaningOnly <$> (o .:? "meaning" .!= "")

contextualMeaningPrompt :: Text -> [Text] -> Text -> Text
contextualMeaningPrompt term contexts general =
  T.intercalate "\n" $
    [ "词条：「" <> term <> "」",
      "它在一个群聊里出现过，下面是群友用到它的几处原话（每处是用到它的那句和它前面一句）："
    ]
      <> concat [["---", context] | context <- contexts]
      <> [ "---",
           "脱离上下文时，这个词一般被理解为：" <> general,
           "",
           "请根据这些原话推断它在这个群里的意思和用法。",
           "- 原话不够推断就把 no_info 设为 true。",
           "- 这个群的用法和上面那个一般理解明显不同时（本群特有的梗、指代、反讽用法），group_specific 为 true；意思基本一样就是 false。",
           "只输出 JSON：{\"meaning\": \"不超过 60 字，写清在这个群里是什么意思、怎么用\", \"group_specific\": false, \"no_info\": false}"
         ]

data JargonInference = JargonInference
  { jiMeaning :: !(Maybe Text),
    jiGroupSpecific :: !Bool
  }
  deriving stock (Show, Eq)

instance FromJSON JargonInference where
  parseJSON = withObject "inference" $ \o -> do
    meaning <- o .:? "meaning" .!= ""
    specific <- o .:? "group_specific" .!= False
    noInfo <- o .:? "no_info" .!= False
    let trimmed = T.strip meaning
        known = not noInfo && not (T.null trimmed)
    pure (JargonInference (if known then Just (T.take 120 trimmed) else Nothing) (known && specific))

parseContextualMeaning :: Text -> Maybe JargonInference
parseContextualMeaning raw = do
  object' <- outermostObject raw
  either (const Nothing) Just (eitherDecodeStrict' (TE.encodeUtf8 object'))

-- | One prompt samples 'promptExpressionSample' of the group's
-- 'promptExpressionPool' most established expressions, and shows at most
-- 'promptJargonMatches' known terms found in the last 'promptJargonWindow'
-- member lines.
promptExpressionPool, promptExpressionSample, promptJargonPool, promptJargonMatches, promptJargonWindow :: Int
promptExpressionPool = 200
promptExpressionSample = 6
promptJargonPool = 500
promptJargonMatches = 4
promptJargonWindow = 40

-- | Weighted sampling without replacement (Efraimidis–Spirakis), keyed by a
-- hash of the seed so one trigger always renders the same sample: previews and
-- the real turn agree, and a retry is not a different prompt.
sampleExpressions :: Int64 -> Int -> [LingoExpression] -> [LingoExpression]
sampleExpressions seed count =
  take (max 0 count) . map snd . sortOn (Down . fst) . map keyed
  where
    keyed expression =
      let u = unitInterval (fnv1a (T.pack (show seed <> ":" <> show expression.leId)))
       in (log u / fromIntegral (max 1 expression.leHits), expression)

unitInterval :: Word64 -> Double
unitInterval h = (fromIntegral (h `shiftR` 11) + 0.5) / 9007199254740992

fnv1a :: Text -> Word64
fnv1a = T.foldl' step 14695981039346656037
  where
    step h c = (h `xor` fromIntegral (fromEnum c)) * 1099511628211

-- | Known terms that occur in the recent lines, newest mention first, then
-- the most established.  Matching ignores links and platform markers.
matchJargon :: Int -> [Text] -> [LingoJargon] -> [LingoJargon]
matchJargon limit recentLines known =
  map snd . take (max 0 limit) . sortOn fst $ mapMaybe locate known
  where
    cleaned = zip [0 :: Int ..] (reverse (map (T.toCaseFold . cleanLingoLine) recentLines))
    locate jargon = do
      let key = termKey jargon.ljTerm
      guard (not (T.null key) && T.any (\c -> not (isPunctuation c || isSymbol c)) key)
      newest <- listToMaybe [age | (age, line) <- cleaned, occursIn key line]
      pure ((newest, Down jargon.ljHits, jargon.ljTerm), jargon)
