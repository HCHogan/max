-- | Sandbox read models contain no registry, locks or runtime closures.
module Max.Sandbox.Types (SandboxId (..), ExecResult (..), SandboxManifest (..), SandboxRead (..), maxOutputBytes) where

import Data.Text (Text)

newtype SandboxId = SandboxId {unSandboxId :: Text}
  deriving stock (Show, Eq, Ord)

maxOutputBytes :: Int
maxOutputBytes = 16 * 1024

data ExecResult = ExecResult
  { erExitCode :: !Int,
    erStdout :: !Text,
    erStderr :: !Text,
    erTruncated :: !Bool,
    -- | When truncated: container-side path holding the full
    -- stdout+stderr up to 'maxSpillBytes' per stream, for the model to
    -- grep/head on demand.
    erSpillPath :: !(Maybe Text),
    -- | True when output exceeded the bounded spill as well as the preview.
    erSpillTruncated :: !Bool,
    erDurationMillis :: !Int,
    erActualCommand :: !Text,
    erNetworkMode :: !Text,
    erStdoutSha256 :: !Text,
    erStdoutBytes :: !Int,
    erStderrSha256 :: !Text,
    erStderrBytes :: !Int,
    -- | Post-effect observation of /work.  This is journal evidence, not a
    -- reconstruction mechanism; the named volume remains the durable state.
    erObservedManifest :: !(Maybe SandboxManifest)
  }
  deriving stock (Show)

-- | A bounded prefix of one sandbox file: UTF-8 text, or only its length
-- when the bytes are binary.
data SandboxRead = SandboxRead {srContent :: !(Maybe Text), srBytes :: !Int, srTruncated :: !Bool}
  deriving stock (Show, Eq)

data SandboxManifest = SandboxManifest
  { smSha256 :: !Text,
    smFileCount :: !Int,
    smPreview :: !Text,
    smTruncated :: !Bool,
    smChangedPaths :: ![Text],
    smChangedPathsTruncated :: !Bool,
    smContainerDiff :: ![Text],
    smContainerDiffTruncated :: !Bool
  }
  deriving stock (Show)
