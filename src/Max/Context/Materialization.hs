module Max.Context.Materialization (MaterializedCompartment (..), ContextMaterialization (..), MaterializationDraft (..)) where

import Data.Aeson
  ( FromJSON (parseJSON),
    KeyValue ((.=)),
    ToJSON (toJSON),
    object,
    withObject,
    (.:),
  )
import Data.Int (Int64)
import Data.Text (Text)
import Data.Time (UTCTime)
import Max.Episode.Types (CompartmentId)
import Max.History.Types (MessageCursor)

data MaterializedCompartment = MaterializedCompartment
  { mcCompartmentId :: !CompartmentId,
    mcProjectionVersion :: !Int64,
    mcTier :: !Text
  }
  deriving stock (Show, Eq)

instance ToJSON MaterializedCompartment where
  toJSON item =
    object
      [ "compartment_id" .= item.mcCompartmentId,
        "projection_version" .= item.mcProjectionVersion,
        "tier" .= item.mcTier
      ]

instance FromJSON MaterializedCompartment where
  parseJSON = withObject "materialized_compartment" $ \o ->
    MaterializedCompartment
      <$> o .: "compartment_id"
      <*> o .: "projection_version"
      <*> o .: "tier"

data ContextMaterialization = ContextMaterialization
  { cmConversationId :: !Int64,
    cmRevision :: !Int64,
    cmEndCursor :: !MessageCursor,
    cmPolicyVersion :: !Text,
    cmSourceFingerprint :: !Text,
    cmItems :: ![MaterializedCompartment],
    cmReason :: !Text,
    cmUpdatedAt :: !UTCTime
  }
  deriving stock (Show, Eq)

data MaterializationDraft = MaterializationDraft
  { mdEndCursor :: !MessageCursor,
    mdPolicyVersion :: !Text,
    mdItems :: ![MaterializedCompartment],
    mdReason :: !Text
  }
  deriving stock (Show, Eq)
