module Max.Agent.FailureSpec (spec) where

import Data.Foldable (for_)
import Max.Agent.Failure
import Max.Http.Failure
import Max.LLM.Failure
import Test.Hspec

spec :: Spec
spec = describe "agent retry classification" $ do
  for_ [408, 429, 500, 503, 529] $ \status ->
    it ("retains transient HTTP status " <> show status <> " regardless of error wording") $ do
      retryableAgentFailure (model (HttpStatusFailure status [] "invalid request; do not retry" False)) `shouldBe` True
  for_ [400, 401, 403, 404, 422] $ \status ->
    it ("does not turn HTTP " <> show status <> " into a retry because its body mentions a provider timeout") $ do
      retryableAgentFailure (model (HttpStatusFailure status [] "upstream provider timeout; HTTP 503; rate limit" False)) `shouldBe` False
  it "retains typed network timeouts without requiring diagnostic text" $ do
    retryableAgentFailure (model ResponseTimeoutFailure) `shouldBe` True
    retryableAgentFailure (model ConnectionTimeoutFailure) `shouldBe` True
    retryableAgentFailure (model (ConnectionFailed "localized diagnostic")) `shouldBe` True
  it "does not retry partial output even when the connection failure was temporary" $ do
    retryableAgentFailure (AgentStreamInterrupted (ResponseTransport ResponseTimeoutFailure)) `shouldBe` False
    retryableAgentFailure (AgentStreamInterrupted (ResponseTransport (ConnectionFailed "reset"))) `shouldBe` False
  it "does not retry configuration, decoding or local budget failures" $ do
    for_ [AgentRoundLimit, AgentModelFailure LLMReleasedConfiguration, AgentModelFailure (LLMUnknownProfile "timeout"), AgentModelFailure (LLMResponseFailure (ResponseDecode "HTTP 503 timeout"))] $ \failure ->
      retryableAgentFailure failure `shouldBe` False
  it "does not retry invalid requests, oversized responses or invalid TLS" $ do
    for_ [RequestConstructionFailure "timeout", ResponseBodyLimitExceeded 3, TlsFailed "certificate expired"] $ \failure ->
      retryableAgentFailure (model failure) `shouldBe` False
  where
    model = AgentModelFailure . LLMResponseFailure . ResponseTransport
