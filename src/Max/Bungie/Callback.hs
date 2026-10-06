-- | The browser end of the Bungie login: Bungie redirects here with the
-- authorization code, and the player sees a small result page.
module Max.Bungie.Callback (handleBungieCallback, callbackPage) where

import Data.Aeson (object, (.=))
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Effectful
import Effectful.Log (Log, logAttention, logInfo)
import Effectful.PostgreSQL (WithConnection)
import Max.Bungie.Account (LoginOutcome (..), completeLogin)
import Max.Bungie.Runtime (BungieRuntime)
import Max.Bungie.Types (AccountIdentity (..))
import Network.HTTP.Types (Status, hCacheControl, hContentType, status200, status400)
import Network.Wai (Response, responseLBS)

handleBungieCallback :: (WithConnection :> es, Log :> es, IOE :> es) => BungieRuntime -> [(Text, Text)] -> Eff es Response
handleBungieCallback runtime params = case (lookup "state" params, lookup "code" params, lookup "error" params) of
  (_, _, Just err) ->
    pure (callbackPage status400 "没有完成授权" ("Bungie 返回：" <> err <> "。需要的话回到聊天里重新发 !destiny login。"))
  (Just state, Just code, Nothing) ->
    completeLogin runtime state code >>= \case
      Right outcome -> do
        logInfo "bungie: account linked" (object ["bungie_name" .= outcome.loAccount.aiBungieName])
        pure . callbackPage status200 "绑定成功" $
          T.concat
            [ "Bungie 账号 ",
              outcome.loAccount.aiBungieName,
              " 已绑定到 ",
              outcome.loRequester,
              "。",
              maybe "（这个账号下还没有命运2角色。）" (const "") outcome.loAccount.aiMembership,
              "现在可以关掉这个页面，回到聊天里继续了。不想用了随时发 !destiny logout 解绑。"
            ]
      Left failure -> do
        logAttention "bungie: login failed" (object ["error" .= failure])
        pure (callbackPage status400 "绑定失败" (if "!destiny login" `T.isInfixOf` failure then failure else failure <> " 回到聊天里重新发 !destiny login 再试一次。"))
  _ -> pure (callbackPage status400 "链接不完整" "请从聊天里收到的登录链接打开，而不是直接访问这个地址。")

callbackPage :: Status -> Text -> Text -> Response
callbackPage status title message =
  responseLBS
    status
    [(hContentType, "text/html; charset=utf-8"), (hCacheControl, "no-store")]
    (LBS.fromStrict (TE.encodeUtf8 page))
  where
    page =
      T.concat
        [ "<!doctype html><html lang=\"zh-CN\"><head><meta charset=\"utf-8\">",
          "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">",
          "<title>",
          escape title,
          " · Max</title><style>",
          ":root{color-scheme:light dark;--bg:#f6f7f9;--card:#fff;--fg:#1d2330;--muted:#5d6676}",
          "@media (prefers-color-scheme:dark){:root{--bg:#101318;--card:#1a1f27;--fg:#e8ebf0;--muted:#9aa3b2}}",
          "body{margin:0;min-height:100vh;display:grid;place-items:center;background:var(--bg);color:var(--fg);",
          "font:16px/1.6 system-ui,-apple-system,\"PingFang SC\",\"Noto Sans CJK SC\",sans-serif}",
          "main{max-width:28rem;margin:1rem;padding:1.75rem 1.5rem;background:var(--card);border-radius:14px;",
          "box-shadow:0 1px 3px rgba(0,0,0,.08)}h1{margin:0 0 .75rem;font-size:1.35rem}p{margin:0;color:var(--muted)}",
          "</style></head><body><main><h1>",
          escape title,
          "</h1><p>",
          escape message,
          "</p></main></body></html>"
        ]
    escape = T.concatMap $ \case
      '<' -> "&lt;"
      '>' -> "&gt;"
      '&' -> "&amp;"
      '"' -> "&quot;"
      '\'' -> "&#39;"
      c -> T.singleton c
