module Max.MCP.ClientSpec (spec) where

import Data.Aeson (Value, object, (.=))
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Max.MCP.Client (decodeRpcBody, mcpTextContent)
import Test.Hspec

-- The JSON-RPC envelope both success cases should decode to.
envelope :: Value
envelope =
  object
    [ "jsonrpc" .= ("2.0" :: String),
      "id" .= (1 :: Int),
      "result" .= object ["ok" .= True]
    ]

spec :: Spec
spec = do
  describe "decodeRpcBody" $ do
    it "parses a plain application/json body" $
      decodeRpcBody (LBS8.pack "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}")
        `shouldBe` Right envelope

    it "parses a text/event-stream body by concatenating data: lines" $
      decodeRpcBody
        ( LBS8.pack $
            "event: message\n"
              <> "data: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}\n\n"
        )
        `shouldBe` Right envelope

    it "fails cleanly on a body that is neither JSON nor SSE" $
      decodeRpcBody (LBS8.pack "not json, no data lines")
        `shouldSatisfy` either (const True) (const False)

  describe "mcpTextContent" $ do
    it "joins text blocks and ignores non-text ones" $ do
      let result =
            object
              [ "content"
                  .= [ object ["type" .= s "text", "text" .= s "line one"],
                       object ["type" .= s "image", "data" .= s "..."],
                       object ["type" .= s "text", "text" .= s "line two"]
                     ]
              ]
      mcpTextContent result `shouldBe` "line one\nline two"

    it "returns empty when there is no content" $
      mcpTextContent (object []) `shouldBe` ""
  where
    s :: String -> String
    s = id
