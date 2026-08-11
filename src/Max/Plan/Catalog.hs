-- | Which of max's real tools a plan may call, and in what shapes.
--
-- ADR 002 step 2 left this open: "Result schemas and plan-level effects are
-- host-owned declarations rather than anything inferred from the tool's name or
-- its description... until then the caller assembles them."  This module is the
-- caller, and assembling them turns out to be the honest bottleneck between the
-- plan kernel and production.  Every other piece — parser, validator, executor,
-- reconciler — was buildable without knowing what any real tool returns.
--
-- __A tool returns @Value@, and no part of max says what shape.__  The argument
-- side is declared: 'Max.Effects.Tools.Tool' carries a JSON Schema, because the
-- model needs one to call it.  Nothing needs the result shape today, because
-- the result goes straight into a model's context as text and a model reads
-- whatever arrives.  A plan cannot: @hits[0].title@ has to type-check before
-- anything runs.  So the result schema is written here, by hand, per tool.
--
-- __Which makes the plannable set small and explicitly so.__  It is a list, not
-- a filter over every registered tool, and a tool absent from it is one nobody
-- has yet read closely enough to say what it returns.  Guessing would be worse
-- than omitting: a wrong result schema type-checks plans against a lie, and the
-- failure surfaces at @hits[0].title@ returning @null@ at runtime, which is
-- exactly the class of error the kernel exists to make impossible.
--
-- The declarations are checked against the live registry rather than trusted:
-- 'planCatalog' joins them by 'ToolRef' and drops anything the host did not
-- register, and "Max.Plan.CatalogSpec" compares each declared input against the
-- JSON Schema the same tool shows the model.  Deriving the input instead would
-- need a JSON-Schema-to-'PlanSchema' converter in production that can fail on
-- constructs the plan language does not have; doing the derivation in a test
-- gets the same drift safety and fails the build instead of a turn.
module Max.Plan.Catalog
  ( PlannableTool (..),
    plannableTools,
    planCatalog,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Max.Effects.Tools (ToolDefinition (..), ToolRef (..))
import Max.Plan.Schema (PlanSchema (..), SchemaField (..))
import Max.Plan.Types (PlanEffect (..), ResourceScope (..))
import Max.Plan.Validate (CatalogEntry, entryFromDefinition)

-- | What a plan needs to know about one tool that the tool registry does not
-- already say.  Version and authority come from the live 'ToolDefinition', so
-- they cannot drift; these three cannot be had any other way.
data PlannableTool = PlannableTool
  { ptRef :: !ToolRef,
    -- | The same shape the tool's JSON Schema describes, in the plan language.
    ptInput :: !PlanSchema,
    -- | What @toolRun@ actually returns on success.  Read off the
    -- implementation, not off the description.
    ptResult :: !PlanSchema,
    -- | Effects as a /plan/ sees them.  Deliberately re-stated rather than
    -- mapped from 'tdEffects': the tool registry's domains are scheduling
    -- identifiers (@network.search@, @conversation.db@) and a plan's scopes are
    -- an authorization vocabulary.  A general mapping between them would be a
    -- guess applied uniformly, which is the worst way to be wrong.
    ptEffects :: !(Set PlanEffect)
  }

field :: Text -> PlanSchema -> SchemaField
field name schema = SchemaField {sfName = name, sfSchema = schema, sfRequired = True}

optional :: Text -> PlanSchema -> SchemaField
optional name schema = SchemaField {sfName = name, sfSchema = schema, sfRequired = False}

-- | One rendered history row, as 'Max.Tools.historyItemSummary' writes it.
messageSummary :: PlanSchema
messageSummary =
  SchemaObject
    [ field "message_id" SchemaInt,
      field "principal_id" SchemaInt,
      field "sender" SchemaText,
      field "time" SchemaText,
      field "text" SchemaText,
      optional "reply_to" SchemaInt
    ]

-- | The plannable set.  Short on purpose, and short because reading a tool
-- closely enough to declare its result is the work — not because the kernel
-- could not handle more.
--
-- Every entry is a read: nothing in a front-of-house plan should be able to
-- send or write, and the ordinary way to get that property is to not declare
-- the tools that can.
--
-- __Fast reads, deliberately.__  The front model is the one that has to stay
-- able to answer, so a plan it runs inline should not block on anything slow;
-- slow work is what a fork child is for, and a child is a durable turn this
-- module has no part in.  So @browser_*@ and @sandbox_exec@ are absent by
-- design rather than by omission, and they stay absent until there is somebody
-- else to run them.
--
-- __Not every tool can be declared at all.__  A result schema is only writable
-- when a tool has one success shape. @browser_navigate@ and @browser_snapshot@
-- hand back whatever the browser container returned, which max does not
-- constrain; @view_zhihu@ has a clean @{url, text, note}@ and a fallback branch
-- that returns the raw payload instead. Declaring either would type-check plans
-- against a shape the tool does not always produce — worse than leaving them
-- out, because the failure lands at runtime on a projection. Making them
-- plannable is a change to /them/: give the success path one total shape.
plannableTools :: [PlannableTool]
plannableTools =
  [ PlannableTool
      { ptRef = ToolRef "web_search",
        ptInput =
          SchemaObject
            [ field "query" SchemaText,
              optional "max_results" SchemaInt
            ],
        -- @answer@ is always present and may be null — aeson encodes the
        -- @Maybe@ as an explicit @null@ rather than omitting the key, so it is
        -- a required nullable field and not an optional one.  The distinction
        -- is not pedantry: an optional field projects to @T?@ as well, but a
        -- plan reading a key that is genuinely absent is a different bug from
        -- one reading a key that is genuinely null.
        ptResult =
          SchemaObject
            [ field "answer" (SchemaNullable SchemaText),
              field
                "results"
                ( SchemaArray
                    ( SchemaObject
                        [ field "title" SchemaText,
                          field "url" SchemaText,
                          field "snippet" SchemaText
                        ]
                    )
                )
            ],
        ptEffects = Set.singleton (EffRead (ExternalScope "web"))
      },
    PlannableTool
      { ptRef = ToolRef "get_message_by_id",
        ptInput = SchemaObject [field "message_id" SchemaInt],
        -- An array because a message may resolve to several rendered rows.
        -- @reply_to@ is emitted only when there is one, so it is optional and
        -- projects to @int?@ — which is what makes walking a quote chain
        -- expressible: @m[0].reply_to ?? 0@ terminates instead of crashing.
        ptResult = SchemaArray messageSummary,
        ptEffects = Set.singleton (EffRead CurrentConversation)
      },
    PlannableTool
      { ptRef = ToolRef "context_search",
        ptInput =
          SchemaObject
            [ field "query" SchemaText,
              optional "limit" SchemaInt
            ],
        -- 'Max.Tools.contextSearchSummary' calls itself the stable model-facing
        -- shape and is kept pure for exactly that reason, so this is a
        -- declaration of something already treated as a contract rather than a
        -- new promise about an incidental encoding.
        ptResult =
          SchemaObject
            [ field "query" SchemaText,
              field "semantic_used" SchemaBool,
              field
                "results"
                ( SchemaArray
                    ( SchemaObject
                        [ field "source" SchemaText,
                          field "score" SchemaNumber,
                          field "time" SchemaText,
                          field "snippet" SchemaText,
                          field "pinned" SchemaBool,
                          field "permanent" SchemaBool,
                          field
                            "match"
                            ( SchemaObject
                                [ field "lexical" SchemaNumber,
                                  field "semantic" SchemaNumber
                                ]
                            ),
                          optional "principal_id" SchemaInt,
                          optional "message_id" SchemaInt,
                          optional "memory_id" SchemaInt,
                          optional "handle" SchemaText
                        ]
                    )
                )
            ],
        ptEffects = Set.singleton (EffRead CurrentConversation)
      },
    PlannableTool
      { ptRef = ToolRef "memory_list",
        ptInput =
          SchemaObject
            [ field "scope" (SchemaEnum ["group", "user"]),
              optional "user_id" SchemaInt
            ],
        ptResult =
          SchemaArray
            ( SchemaObject
                [ field "id" SchemaInt,
                  field "version" SchemaInt,
                  field "lifecycle" SchemaText,
                  field "content" SchemaText
                ]
            ),
        ptEffects = Set.singleton (EffRead CurrentConversation)
      }
  ]

-- | Join the declarations against what the host actually registered for this
-- dispatch.
--
-- A declared tool the host did not register is dropped rather than reported: a
-- gated tool absent from this dispatch is absent for the same reasons it is
-- absent from the model's own tool list, and a plan catalog advertising it
-- would promise a call that cannot be made.  The reverse — a registered tool
-- with no declaration — is simply not plannable, which is the default.
planCatalog :: [ToolDefinition] -> Map ToolRef CatalogEntry
planCatalog registered =
  Map.fromList
    [ (tool.ptRef, entryFromDefinition definition tool.ptInput tool.ptResult tool.ptEffects)
      | tool <- plannableTools,
        Just definition <- [Map.lookup tool.ptRef byRef]
    ]
  where
    byRef = Map.fromList [(definition.tdRef, definition) | definition <- registered]
