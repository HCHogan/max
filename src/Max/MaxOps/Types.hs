module Max.MaxOps.Types
  ( MaxOpsConfig (..),
    defaultMaxOpsConfig,
    validateMaxOpsConfig,
    maxOpsAllowed,
  )
where

import Data.Int (Int64)
import Data.List (isPrefixOf)
import Data.Text (Text)
import Data.Text qualified as T
import Network.URI (URI (..), URIAuth (..), parseURI)
import OneBot.Types (GroupId (..))
import System.FilePath (isAbsolute)

data MaxOpsConfig = MaxOpsConfig
  { mocEnabled :: !Bool,
    mocBaseUrl :: !Text,
    mocTokenFile :: !FilePath,
    mocAllowedGroups :: ![Int64]
  }
  deriving stock (Eq, Show)

defaultMaxOpsConfig :: MaxOpsConfig
defaultMaxOpsConfig = MaxOpsConfig False "http://127.0.0.1:9721" "" []

validateMaxOpsConfig :: MaxOpsConfig -> [Text]
validateMaxOpsConfig config =
  ["maxops.allowed_groups" | any (<= 0) config.mocAllowedGroups]
    <> ["maxops.base_url" | config.mocEnabled && not validUrl]
    <> ["maxops.token_file" | config.mocEnabled && not validTokenFile]
  where
    validUrl = case parseURI (T.unpack config.mocBaseUrl) of
      Just uri ->
        uri.uriScheme `elem` ["http:", "https:"]
          && null uri.uriQuery
          && null uri.uriFragment
          && maybe False (\authority -> null authority.uriUserInfo && not (null authority.uriRegName)) uri.uriAuthority
      Nothing -> False
    validTokenFile = isAbsolute config.mocTokenFile && not ("/nix/store/" `isPrefixOf` config.mocTokenFile)

maxOpsAllowed :: MaxOpsConfig -> GroupId -> Bool
maxOpsAllowed config (GroupId group) =
  config.mocEnabled && group > 0 && group `elem` config.mocAllowedGroups && null (validateMaxOpsConfig config)
