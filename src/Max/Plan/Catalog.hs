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
    toolPlanEffects,
    childReachableEffects,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Max.Effects.Tools (ToolDefinition (..), ToolEffect (..), ToolRef (..))
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
    ptResult :: !PlanSchema
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
-- slow work is what a fork child is for.  So @browser_*@ and @sandbox_exec@ are
-- absent by design rather than by omission.
--
-- They are no longer absent from a /child/, which is what issue #17.E fixed:
-- see 'toolPlanEffects'.  This list stayed the child's ceiling long after it
-- stopped being the right one, because a result schema and an authorization
-- scope were written in the same record and only one of them is a child's
-- business.
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
            ]
      },
    PlannableTool
      { ptRef = ToolRef "get_message_by_id",
        ptInput = SchemaObject [field "message_id" SchemaInt],
        -- An array because a message may resolve to several rendered rows.
        -- @reply_to@ is emitted only when there is one, so it is optional and
        -- projects to @int?@ — which is what makes walking a quote chain
        -- expressible: @m[0].reply_to ?? 0@ terminates instead of crashing.
        ptResult = SchemaArray messageSummary
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
            ]
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
            )
      }
  ]

-- | What a tool does, in the vocabulary a @Goal@'s budget is written in.
--
-- Split out of 'PlannableTool' for issue #17.E.  The two questions a plan asks
-- about a tool are not the same question, and binding them together is what
-- made @Fork@ mean almost nothing:
--
--   * /May a plan expression call it?/ — needs 'ptResult', because
--     @hits[0].title@ has to type-check before anything runs.
--   * /May a fork child call it?/ — does not.  A child's typed boundary is
--     @subgoal_return@, whose schema is the goal's expected type; what the
--     child does on the way there never crosses a plan expression at all.
--
-- Because both lived in one record, a child's ceiling was "somebody hand-wrote
-- a result schema", so a fork bought parallel @web_search@ and nothing else —
-- the exact opposite of ADR 007 §553, which says the split is by latency and
-- names Browser, Sandbox and Video as belonging in children.
--
-- __Still hand-written per tool.__  The warning this module used to carry on
-- 'ptEffects' was right and is kept: registry domains are scheduling
-- identifiers and plan scopes are an authorization vocabulary, so a general
-- @domain -> scope@ function would be a guess applied uniformly.  It fails
-- concretely, not just in principle — @sandbox.fs@ cannot say /which/ sandbox
-- and @network.search@ cannot name the origin an approval binds, because
-- neither is in the domain.  What changed is only that a judgement about a
-- tool's authority no longer costs a judgement about its result shape.
--
-- __When unsure, declare more.__  Effects are checked by
-- @isSubsetOf effects budget@, so a declaration that is too narrow lets a
-- budget admit a tool it did not mean to and a declaration that is too wide
-- only makes the tool unreachable.  The failure directions are not symmetric,
-- and 'view_avatar' below is where that shows.
toolPlanEffects :: Map ToolRef (Set PlanEffect)
toolPlanEffects =
  Map.fromList $
    [ -- The four that were already plannable, unchanged.
      (ToolRef "web_search", Set.singleton (EffRead (ExternalScope "web"))),
      (ToolRef "get_message_by_id", Set.singleton (EffRead CurrentConversation)),
      (ToolRef "context_search", Set.singleton (EffRead CurrentConversation)),
      (ToolRef "memory_list", Set.singleton (EffRead CurrentConversation)),
      -- Reading media the conversation already holds.  @blob.store@ is a
      -- host-wide store, but the only way into it here is a handle this
      -- conversation produced, so what is reached is still this conversation.
      -- @tool.media@ is not a resource at all; it marks that the result lands
      -- in the turn's own output, which is why these are SequentialOnly.
      (ToolRef "view_image", Set.singleton (EffRead CurrentConversation)),
      (ToolRef "view_video", Set.singleton (EffRead CurrentConversation)),
      -- Two effects, not one.  Whose avatar is a fact about this conversation's
      -- membership, and fetching it leaves the host for the platform's CDN —
      -- both are true, so a budget has to admit both.  Declaring only the first
      -- would let a conversation-only budget reach off-host, which is the
      -- narrow-side mistake this table is written to avoid.
      ( ToolRef "view_avatar",
        Set.fromList [EffRead CurrentConversation, EffRead (ExternalScope "platform")]
      ),
      (ToolRef "view_bilibili", Set.singleton (EffRead (ExternalScope "bilibili"))),
      -- The sandbox set, on the same argument as the browser one below: these
      -- tools already declare @ProcessResource "sandbox"@ as their authority,
      -- so @ProcessScope "sandbox"@ restates a hand-made declaration rather
      -- than inventing a second opinion about what a sandbox is.
      --
      -- Not 'SandboxScope', which was the first answer and the wrong one.  Its
      -- 'Text' names /which/ sandbox, and a child picks one at runtime by
      -- argument, so nothing static can fill it in — but the question was never
      -- this layer's to answer.  'Max.Sandbox.Registry.listSandbox' already
      -- refuses a handle belonging to another conversation, and says so:
      -- /"Wrong-group requests get 'Nothing' (so we don't leak cross-group
      -- sandbox ids)"/.  What a budget needs to express is whether this child
      -- may use the conversation's sandboxes at all, and that is a process
      -- resource.  'SandboxScope' keeps its meaning for a plan expression that
      -- has bound a specific handle.
      (ToolRef "sandbox_list", Set.singleton (EffRead (ProcessScope "sandbox"))),
      (ToolRef "sandbox_read_file", Set.singleton (EffRead (ProcessScope "sandbox"))),
      (ToolRef "sandbox_create", Set.singleton (EffWrite (ProcessScope "sandbox"))),
      (ToolRef "sandbox_destroy", Set.singleton (EffWrite (ProcessScope "sandbox"))),
      (ToolRef "sandbox_write_file", Set.singleton (EffWrite (ProcessScope "sandbox"))),
      -- Reads a blob this conversation produced and writes it into a sandbox.
      ( ToolRef "import_file_to_sandbox",
        Set.fromList [EffRead CurrentConversation, EffWrite (ProcessScope "sandbox")]
      ),
      -- Runs in the container, so it is also whatever the container can reach.
      ( ToolRef "nix_search",
        Set.fromList [EffRead (ProcessScope "sandbox"), EffRead (ExternalScope "nix")]
      ),
      -- The widest thing in the catalog, and declared that way on purpose.  A
      -- sandbox with a network can reach anything from inside a shell command,
      -- and the network mode is per-sandbox configuration rather than anything
      -- this static declaration can see.  So a budget has to grant the open
      -- network before a child may run arbitrary code — which is the
      -- conservative reading and the one a reader would expect to be true.
      ( ToolRef "sandbox_exec",
        Set.fromList [EffWrite (ProcessScope "sandbox"), EffRead (ExternalScope "network")]
      )
    ]
      <> [(ToolRef name, browserEffects) | name <- browserRefs]

-- | @browser.session@ is a host process resource, and the tools already say so
-- themselves: every one of them declares @ProcessResource "browser"@ as its
-- authority.  Naming it @ProcessScope "browser"@ restates an existing hand-made
-- declaration in the scope vocabulary rather than inventing a second opinion
-- about what a browser is.
--
-- The read is the same @external "web"@ that @web_search@ carries, on purpose:
-- searching the open web and navigating it are one authorization class, and a
-- budget that admits reading the web should not have to enumerate the two ways
-- of doing it.
browserEffects :: Set PlanEffect
browserEffects =
  Set.fromList [EffWrite (ProcessScope "browser"), EffRead (ExternalScope "web")]

browserRefs :: [Text]
browserRefs =
  [ "browser_navigate",
    "browser_snapshot",
    "browser_click",
    "browser_type",
    "browser_press_key",
    "browser_wait_for",
    "browser_scroll",
    "view_zhihu"
  ]

-- | The effects a fork child's goal must admit before it may call this tool,
-- or 'Nothing' if no judgement has been made about it.
--
-- 'Nothing' is a refusal, not a default: a tool nobody has placed in the
-- authorization vocabulary is one a child cannot have.
--
-- __A child still cannot speak.__  Any tool that sends is refused here whatever
-- else is declared about it, and structurally rather than by remembering to
-- leave it out of the table — the invariant is that a child hands its answer
-- back through @subgoal_return@ and reaches nobody directly, and it should not
-- rest on a list staying correct.
--
-- Together with the structural rules, this is what makes ADR 007 §553 true:
-- Browser, Sandbox and Video are the three it names as belonging in children,
-- and a goal that admits their effects can now have them.
childReachableEffects :: ToolDefinition -> Maybe (Set PlanEffect)
childReachableEffects definition
  | any isSend definition.tdEffects = Nothing
  | otherwise = Map.lookup definition.tdRef toolPlanEffects
  where
    isSend = \case
      EffectSend {} -> True
      _ -> False

-- | Join the declarations against what the host actually registered for this
-- dispatch.
--
-- A declared tool the host did not register is dropped rather than reported: a
-- gated tool absent from this dispatch is absent for the same reasons it is
-- absent from the model's own tool list, and a plan catalog advertising it
-- would promise a call that cannot be made.  The reverse — a registered tool
-- with no declaration — is simply not plannable, which is the default.
-- Effects come from 'toolPlanEffects' rather than from the entry, so a tool's
-- authorization story is written in exactly one place whichever of the two
-- questions is being asked about it.  A plannable tool missing from that table
-- is dropped, and "Max.Plan.CatalogSpec" fails the build if one ever is.
planCatalog :: [ToolDefinition] -> Map ToolRef CatalogEntry
planCatalog registered =
  Map.fromList
    [ (tool.ptRef, entryFromDefinition definition tool.ptInput tool.ptResult effects)
      | tool <- plannableTools,
        Just definition <- [Map.lookup tool.ptRef byRef],
        Just effects <- [Map.lookup tool.ptRef toolPlanEffects]
    ]
  where
    byRef = Map.fromList [(definition.tdRef, definition) | definition <- registered]
