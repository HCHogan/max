# ADR 003: Message IR and Capability-Tiered Rendering

- Status: Accepted
- Date: 2026-08-04

## Context

Max stores one canonical message per semantic event (ADR-less migration 049)
and fans deliveries out to conversation endpoints. The ledger layer —
`conversations` / `conversation_endpoints` / `principals` /
`message_deliveries` with leases, idempotency keys, and outcome-unknown
parking — has held up well. The content layer has not. Every recent
mirror-related incident (42df035, ccf339d, a69a52f, 300448d, e8f72fb,
2f9b4da; repair migrations 051/053/054) falls on the same fault line.

### One message, three stored representations

- `messages.segments` — OneBot `Segment` jsonb. Nominally QQ provenance, but
  outbound bot messages are *executed* from it (`compatibilitySegments`,
  `Max.Platform.Delivery.oneBotSegments`).
- `messages.canonical_content` — `ContentPart` jsonb. Nominally the neutral
  representation, but far poorer than `Segment`: text/mention/media/
  unsupported only. Faces, cards, files, videos, stickers, and replies are
  degraded to text or `ContentUnsupported` *at ingest*
  (`Max.Platform.QQ.qqContentParts`), unrecoverably.
- `messages.rendered_text` — a text projection computed once at write time
  and consumed by ~20 modules: prompts, mirror delivery, historian,
  embeddings, recall, search.

Migration 053 had to re-pair canonical media parts with segments *by rank*
because the two representations had drifted. Migration 054 had to rewrite
`rendered_text` because one stored projection cannot simultaneously satisfy
the QQ prompt contract (`[@#123]`) and a platform-neutral display (`@name`).
Replies are stored in four places (`SegReply`, `reply_to_message_id`,
`reply_to_canonical_message_id`, `message_relations`); migration 051 had to
repair all of them.

### Rendering is scattered and inconsistent

At least six canonical→text renderers exist, disagreeing on separators,
mention forms, and media placeholders: `renderCanonicalText` (Store.hs,
`intercalate " "`), `matrixCanonicalText` (Matrix.hs, `T.concat`),
`renderMatrixContent` (Matrix.hs), the SQL renderers inside migrations
053/054, `renderOutbound` (Wechatpad.hs), and `attributedText` +
`oneBotSegments` (Delivery.hs). The mention fix in 42df035 patched only the
Matrix transport; the OneBot mirror branch still ships `claim.renderedText`
verbatim, so QQ structural tokens leak into wechatpad mirrors, and the
iMessage transport sends `renderedText` with no attribution prefix at all.
Attribution labels, media placeholders (`[图片]` vs `[image]` vs `[media]`),
and "first attachment only" truncation are each implemented several times
with different behavior.

### Capabilities are three disjoint systems

- `PlatformCapabilities` (endpoint jsonb): the delivery worker checks only
  `send_text` and `max_text_bytes` — and oversize is a *permanent failure*
  rather than a chunked send. `can_edit`/`can_redact` are stored and never
  read. Matrix declares `canReact=True` with no outbound implementation.
- `ConversationOutputCapabilities`: a per-conversation `bool_and`
  intersection with hand-carved QQ exceptions (`canOutputQQMention` via
  `bool_or`, faces via `bool_and`). The intersection semantics (e8f72fb) and
  the per-endpoint exception (42df035) are two models fighting in one
  structure. The Matrix `canReact` misdeclaration flows through the
  intersection and makes the bot attempt `SetMsgEmojiLike` routed to a
  platform with no `PlatformBackend` — a runtime error by construction.
- `PlatformApi` actions (reactions, pokes, file ops) bypass capability
  checks and the durable outbox entirely.

### Semantics are destroyed at ingest, then missed at egress

- QQ: faces/cards/videos/files become text or `ContentUnsupported` in
  canonical content; recall and reaction notices are dropped as `EvRaw`.
- Matrix: non-self `m.mentions` never become `ContentMention`; the reply
  fallback quote (`> …`) is not stripped from the body; `m.new_content` of
  edits is not extracted; redaction targets overload the `Replaces`
  relation.
- iMessage: non-bot mentions in `attributedBody` are dropped; compat
  segments flatten attachments to `[media: name]`, so the vision pipeline
  never fires for non-QQ media.
- wechatpad: still outside the canonical pipeline entirely (legacy
  `insertGroupMessage`, no mirror fan-out), yet registered as a canonical
  delivery transport — half-migrated, and its `renderOutbound` silently
  deletes mentions and replies.
- Mirrors: only `EventMessage` fans out; edits, reactions, and redactions
  never cross platforms. OneBot mirrors keep only `image/*` media; Matrix
  and iMessage send only the first attachment and silently degrade on
  upload failure.

The root cause, stated once: **rendering happens at write time with one
global projection, while the consumers — N endpoints plus the prompt — have
different capabilities.** Every patch since the 049 cutover has been a
site-local correction of that mismatch.

## Decision

Replace the content layer with a single rich message IR, stored once, and
move all rendering to the edges as pure, capability-driven *lowering*. The
ledger layer (conversations, endpoints, principals, deliveries, relations,
leases, echo reconciliation) is explicitly retained.

### 1. The IR: one phase-indexed node list, every node carries its own fallback

`Max.IR.Types`. A message body is an ordered list of nodes. Envelope facts
(author, conversation, timestamps) stay in the ledger; relations
(reply/edit/reaction/redaction) stay in `message_relations` and never appear
in the body.

The tree is indexed by pipeline phase, borrowing the skeleton of Trees That
Grow but deliberately pruned (see below). The shape is identical across
phases; only the decorations at four slots change. Adapters construct
`Ingest`; model parsing constructs `ModelParsed`; only `Canonical` is stored:

```haskell
data Phase = ModelParsed | Ingest | Canonical | Lowered | Hydrated

data Body (p :: Phase) = Body { nodes :: ![Node p] }

data Node (p :: Phase)
  = NText !Text
  | NMention !(XMention p) !Text        -- target + display (universal fallback)
  | NEmote !Emote                       -- platform face/emote
  | NMedia !(XMedia p) !MediaMeta       -- image/sticker/video/audio/file
  | NCard !Card                         -- structured share (lightapp, preview)
  | NForward !(XForward p)              -- merged-forward container marker
  | NUnsupported !(XUnsupported p)

type family XMention (p :: Phase) where
  XMention 'ModelParsed = NativeUserId    -- raw [@#123] token, pre-roster
  XMention 'Ingest      = NativeUserId    -- adapter-authenticated native id
  XMention 'Canonical   = MentionTarget   -- MentionIdentity … | MentionAll
  XMention 'Lowered     = NativeUserId    -- DESTINATION endpoint's native id;
                                          -- constructible only via identity map
  XMention 'Hydrated    = HydratedMention -- principal + every linked identity

type family XMedia (p :: Phase) where
  XMedia 'ModelParsed = OutboundMediaRef  -- [sticker#42] / [image#7] reference
  XMedia 'Ingest      = Maybe MediaRef    -- normalized adapter reference
  XMedia 'Canonical   = Maybe MediaRef    -- blob:<sha256> | http(s)/mxc URL | none;
                                          -- never inline bytes at rest
  XMedia 'Lowered     = ResolvedMedia     -- sendable payload, NOT Maybe:
                                          -- sourceless media must fold to text
  XMedia 'Hydrated    = MediaView         -- authed blob URL, thumbnail, size

type family XForward (p :: Phase) where
  XForward 'Ingest    = ForwardRef
  XForward 'Canonical = ForwardRef        -- children are canonical messages
  XForward 'Hydrated  = HydratedForward   -- children as canonical-message links
  XForward _          = Void              -- model can't author; lowering folds

type family XUnsupported (p :: Phase) where
  XUnsupported 'Ingest = Unsupported
  XUnsupported 'Canonical = Unsupported
  XUnsupported 'Hydrated  = Unsupported   -- raw payload inspectable in admin
  XUnsupported _          = Void          -- can never reach a wire

type ForAllX c p = (c (XMention p), c (XMedia p), c (XForward p), c (XUnsupported p))
deriving stock instance ForAllX Eq p => Eq (Node p)
deriving stock instance ForAllX Show p => Show (Node p)

data MentionTarget
  = MentionIdentity !PrincipalIdentityId  -- knows principal AND origin native id
  | MentionAll

data Emote = Emote
  { origin   :: !Platform
  , nativeId :: !Text
  , name     :: !(Maybe Text)           -- "惊讶"; fallback text
  , raw      :: !(Maybe Value)          -- same-platform round-trip payload
  }

data MediaMeta = MediaMeta              -- universal across phases
  { kind        :: !MediaKind           -- MImage | MSticker | MVideo | MAudio | MFile
  , mime        :: !(Maybe Text)
  , sizeBytes   :: !(Maybe Int64)
  , name        :: !(Maybe Text)        -- filename
  , description :: !(Maybe Text)        -- caption / summary; human fallback
  , raw         :: !(Maybe Value)       -- e.g. QQ file_id for native re-send
  }

data Card = Card
  { title   :: !(Maybe Text)
  , subtitle:: !(Maybe Text)
  , url     :: !(Maybe Text)
  , tag     :: !(Maybe Text)            -- "哔哩哔哩"
  , preview :: !(Maybe MediaRef)
  , raw     :: !(Maybe Value)           -- lightapp JSON for native round-trip
  }

data ForwardRef = ForwardRef
  { nativeId :: !Text
  , count    :: !(Maybe Int)
  }                                      -- children linked via contained_in

data Unsupported = Unsupported
  { source      :: !Text                -- "qq:record"
  , description :: !Text                -- REQUIRED human-readable fallback
  , raw         :: !(Maybe Value)
  }
```

Phase transitions are the pipeline: `resolve :: Body 'ModelParsed -> Eff es
(Body 'Canonical)` (roster/sticker lookup in ReplySend), `resolveIngest ::
(NativeUserId -> Text -> Eff es (MentionTarget, Text)) -> Body 'Ingest ->
Eff es (Body 'Canonical)` (principal identity resolution at durable ingest), `lower :: LowerEnv
-> Body 'Canonical -> Lowered` (section 2, degradation), `hydrate :: Body
'Canonical -> Eff es (Body 'Hydrated)` (section 5, enrichment for the admin
surface), and only `Body 'Canonical` has JSON instances — the stored codec
is pinned to exactly one phase.

What this buys, mapped to observed defect classes: an unresolved or
origin-platform mention cannot reach a transport (the 42df035 class becomes
unrepresentable — a `Lowered` mention holds a destination-endpoint id or was
folded to `@display`); sourceless media cannot reach `emit` (`ResolvedMedia`
is not `Maybe`); `NUnsupported`/`NForward` cannot leak into wire text
(`Void`, discharged by `absurd`); inline bytes cannot enter the stored form
(`XMedia 'Canonical` has no bytes case); the roster check in mention parsing
is a typed obligation of `resolve` rather than a convention.

What is deliberately rejected from full Trees That Grow: the extension
constructor (`XNode`) — the tree stays **closed**, which is load-bearing for
both the totality of `fallbackText` and the stored format's versioned
schema (platform-private content is a value-level `NUnsupported`, not a
type-level extension); per-constructor extension fields and `XRec` child
wrappers (GHC's main noise sources — our phases replace fields, they don't
annotate every node); and platform-as-index (degradation depends on runtime
caps rows, which types cannot see — a platform index would only fragment
the stored format). The caps-tier-compliance invariant itself stays a
property test: caps are data, not types.

Design rules:

- **Total fallback.** `fallbackText :: Node 'Canonical -> Text` is a total
  function implemented exactly once. Every constructor either is text or carries
  enough captured context (display name, emote name, media description,
  card title/url) to render as readable text with no lookups. Degradation
  can therefore never fail and never needs IO.
- **Mentions target identities, not raw ids.** `PrincipalIdentityId`
  resolves to a principal, which resolves (or not) to an identity on any
  destination platform. That single fact decides native-vs-text mention
  lowering per endpoint. The captured `display` is the text tier.
- **Native round-trip via `raw`.** When origin platform == destination
  platform, the adapter may reconstruct the native form (QQ face id,
  file_id, lightapp card) from the preserved payload. `segments` stops
  being a second source of truth.
- **Relations, not in-body markers.** `SegReply`-in-content dies.
  `message_relations` grows a `redacts` kind (no more overloading
  `replace`); edit events carry their new body as their own canonical
  content. `reply_to_canonical_message_id` remains as a derived convenience
  column; `reply_to_message_id` is frozen legacy.
- **Versioned encoding.** `canonical_content` becomes
  `{"v":2,"nodes":[...]}`. Runtime application code accepts v2 only. A
  one-shot offline backfill lifts v1 (consulting `segments` to recover
  faces/cards/replies that v1 destroyed) and stamps v2 while the old
  service is stopped, before the new binary starts serving. The migration
  may decode legacy rows; the deployed application may not.

### 2. Lowering: one degradation library; adapters only emit

`Max.IR.Lower` is the single place degradation happens:

```haskell
lower :: LowerEnv -> Body 'Canonical -> LoweredMessage

data LowerEnv = LowerEnv
  { platform      :: !Platform            -- native emotes need origin match
  , caps          :: !OutboundCaps
  , attribution   :: !(Maybe Attribution) -- mirror prefix, one impl
  , mentionNative :: !(PrincipalIdentityId -> Maybe NativeUserId)
                      -- pre-resolved against destination endpoint, pure
  , mediaResolve  :: !(MediaRef -> Maybe ResolvedMedia)
  , replyTarget   :: !(Maybe ReplyContext) -- native id + quote fallback facts
  }

data LoweredMessage = LoweredMessage      -- ("Lowered" clashes with 'Lowered)
  { replyNative :: !(Maybe NativeEventId)
  , chunks      :: ![[Node 'Lowered]]  -- max_text_bytes chunking done here
  , notes       :: ![LowerNote]        -- every degradation/drop, audit data
  }
```

The phase index enforces part of the output contract for free: a
`Node 'Lowered` mention necessarily carries a destination-native id, its
media is necessarily resolved, and `NUnsupported`/`NForward` are
uninhabited. The remaining invariant — only node kinds the endpoint's caps
declare `TierNative` survive as structure — is runtime data and stays a
property test over `lower`.

- An adapter's transport becomes `emit :: Lowered -> wire` and contains
  **zero** degradation branches. If a node reaches `emit`, the endpoint
  declared it native; everything else was already folded into `LText` by
  the shared library (mention → `@display`, reply → quote block
  `「name: excerpt」`, media → `[图片: caption]` / `[文件: name (size)]`,
  emote → `[表情: name]`, card → `title — url`). Placeholder vocabulary
  exists once.
- Attribution (`[QQ · 昵称]`) is a lowering concern with a single
  implementation, applied whenever `attribution` is set — which the claim
  determines (inbound mirror), not the transport.
- `max_text_bytes` triggers chunking inside `lower`, replacing the current
  permanent-failure behavior in `deliveryCapabilityError`.
- Media beyond the endpoint's `maxNativeMedia` budget degrades to text
  lines (name + url when available) inside the same pass — never silently
  dropped. Upload failures at emit time fall back to the already-computed
  text tier and record a note; today they silently vanish.

### 3. Capabilities: typed, three explicit tiers, one consumer path

```haskell
data Tier = TierNative | TierText | TierDrop

data OutboundCaps = OutboundCaps
  { text          :: !Bool
  , mention       :: !Tier
  , reply         :: !Tier      -- TierText = quote-block fallback
  , emote         :: !Tier
  , image, sticker, video, audio, file, card :: !Tier
  , reaction      :: !Bool      -- meta-actions: native or nothing
  , edit          :: !Bool
  , redact        :: !Bool
  , maxTextBytes  :: !(Maybe Int)
  , maxNativeMedia:: !Int
  }
```

- Stored per endpoint (same jsonb column), parsed by one total decoder;
  missing/unknown fields default to the safe tier (`TierText` for content —
  always achievable thanks to total fallbacks; `False` for meta-actions).
  `TierDrop` is a deliberate, declared choice (e.g. emotes on quiet
  platforms), never an accident of a missing case branch.
- The wechatpad "silently delete mentions" behavior and the Matrix
  `canReact` misdeclaration both become impossible states: adapters ship a
  `defaultCaps` alongside their transport, and the only consumer of caps is
  the lowering library plus the action router.
- Dynamic capability (iMessage IMCore reply probe) stays: the adapter
  rewrites its endpoint caps row, exactly as today.
- `ConversationOutputCapabilities` (intersection + QQ exceptions) is
  deleted. What the model is allowed to do is derived instead:

```haskell
data AdvertisedCaps = AdvertisedCaps
  { canReply    :: Bool  -- always True: every endpoint gets native or quote
  , canMention  :: Bool  -- always True: native or @display
  , canMedia    :: Bool  -- True if any endpoint >= TierText
  , canReaction :: Bool  -- True iff some endpoint holding a native copy
                         -- of the target declares reaction natively
  , canFace     :: Bool  -- True iff a QQ endpoint is present
  }
```

  Because content degradation is total, semantic actions no longer need to
  be hidden from the model when a weak endpoint joins the conversation —
  the lowest-common-denominator problem disappears. Only genuinely
  non-degradable actions (reactions, QQ faces) stay gated, and reactions
  degrade to no-op on incapable endpoints (quiet by default, per operator
  preference) rather than to text spam.

### 4. The prompt is the N+1th render target

The LLM-facing transcript is produced by the same pipeline: a `promptCaps`
target whose emit stage writes the existing model contract tokens —
`[@#<qq>]`, `[↩#<id>]`, `[image#<id>: …]`, `[sticker#<id>]`, `[face#<id>:
name]`, `[card: …]`. **The model contract does not change**; persisted
history and the trained token vocabulary keep working. What changes is the
source: tokens are emitted from IR nodes instead of from a stored
`rendered_text`, and `Max.Reply`/`ReplySend` parse model output *into IR
nodes* (mention tokens → `NMention` resolved against the roster, sticker
tokens → `NMedia`, reply tokens → a reply relation) instead of into OneBot
segments.

Consequences:

- Bot replies and mirror deliveries share one outbound path:
  `enqueueOutbound` stores IR; per-endpoint lowering renders it. The
  `renderedText` / `compatibilitySegments` fields on `DeliveryClaim` are
  deleted.
- `rendered_text` becomes a derived, regenerable projection with exactly
  one audience (prompt/search/embedding, primary-endpoint flavored — the
  054 lesson made explicit). It is written by the one plain emitter at
  ingest and can be rebuilt wholesale from IR by a maintenance command. No
  delivery path may read it.
- `segments` is demoted to QQ raw provenance: written on QQ ingest, read
  only by the QQ same-platform `raw` round-trip, frozen for other
  platforms.

### 5. Read-side render targets: admin and logs are not endpoints

The admin API/UI is the fourth consumer family, and the only one that
*enriches* instead of degrading. It gets its own phase instantiation and a
`hydrate` transition: `blob:<sha>` sources become authenticated
`/api/blobs/<sha>` links with thumbnails; a mention resolves to its
principal plus every linked platform identity; `NUnsupported` exposes its
raw payload for inspection; `NForward` links to its canonical children.
Exhaustiveness does the maintenance work: a future node kind cannot be
forgotten by the admin view any more than by a transport.

Deliberately **not** an endpoint: the admin server is in-process and the
ledger is the source of truth, so the timeline reads `conversation_seq`
directly with LISTEN/NOTIFY for live tail. A viewer needs no delivery rows,
no leases, no capability row — modelling it as a `conversation_endpoints`
entry would pollute the outbox for nothing.

What the admin surface can show that no chat platform can:

- The pre-degradation truth (hydrated canonical body) next to each
  endpoint's delivery row — status, native event id, attempts, last error.
- **Per-delivery degradation audit.** `lower`'s notes are promoted from
  log lines to data: a `message_deliveries.lower_notes jsonb` column
  records exactly what each endpoint's copy degraded or dropped
  (`mention→drop`, `image→"[图片]"`). "Why is the @ missing on the WeChat
  mirror" becomes a click instead of a journalctl session.
- The conversation's capability matrix (each endpoint's Tier per node
  kind), mirror topology, backlog/parked/poison counts.

An admin write path ("speak as bot", broadcast) needs no new machinery
whenever it is wanted: it is an ordinary bot-origin `enqueueOutbound` with
an IR body, flowing through per-endpoint lowering like any reply.

Logs are the fifth consumer, and the only phase-polymorphic one. Today
message content reaches the log via ad-hoc `renderPlainText` calls
(e.g. Handler.hs) — unbounded, unstable shapes, one more fork. It becomes a
single bounded digest emitter:

```haskell
class LogDecor x where decorDigest :: x -> Text
digest :: ForAllX LogDecor p => Body p -> Value
```

Its contract is the inverse of the others: **bounded, pointers not
payloads**. Per-node compact form plus a whole-line cap
(`text(42B)+mention(@张三)+image(blob:ab12…,182KB)`), stable structured
keys (canonical id, blob shas, byte counts) for journalctl grep — full
content always lives in the DB, never in the line. Phase polymorphism is
the payoff: ingest logs the `Canonical` digest, delivery logs the
`Lowered` digest (exactly what went to the wire), ReplySend logs
`ModelParsed`; delivery logs also carry the same `lower_notes` the audit
column stores.

The full consumer roster, for symmetry: chat endpoints = `lower` + `emit`
(capability degradation); LLM prompt = token codec (bidirectional);
`rendered_text`/search/embedding = plain emit (total text); admin =
`hydrate` (zero-loss enrichment); logs = `digest` (bounded,
phase-polymorphic). One tree, five projections, each implemented once.
What these consumers share is the closed tree and a single emit apiece —
**not** the endpoint apparatus: viewers and logs get no capability rows
and no deliveries. Read-side consumers need bounds or enrichment, not
caps.

### 6. Meta-events mirror by capability

Mirror fan-out (`ingestEnvelope`) extends beyond `EventMessage`: edits,
reactions, and redactions produce deliveries **only to endpoints whose caps
declare the action natively** — no text-degradation tier for meta-events by
default (a mirrored "(撤回了一条消息)" line is opt-in config, not default,
keeping mirrors quiet). Reactions route via the same native-copy resolution
used by replies (`platform_events ∪ message_deliveries`), fixing both the
"react on a platform with no backend" error and the fire-and-forget bypass:
reaction sends move into the durable outbox as lightweight deliveries.

Inbound completeness work this unlocks (adapter fixes, same IR):

- QQ: parse recall and reaction notices (today `EvRaw`); faces → `NEmote`;
  cards → `NCard`; files/videos → `NMedia` — ingest stops degrading.
- Matrix: extract `m.new_content`; strip the reply fallback quote from
  bodies; map non-self `m.mentions` → `NMention`; use the new `redacts`
  relation.
- iMessage: map all `attributedBody` mention ranges → `NMention`.
- wechatpad: enter the canonical pipeline (endpoint registration,
  `InboundEnvelope` ingest, mirror fan-out) with honest text-only caps.

### 7. Correctness fixes folded into the same work

These are known defects the refactor passes through; fix them in place:

- Reply/native-target resolution uses `LIMIT 1` with no `ORDER BY`
  (Store.hs claim subquery and `resolveReply`): add deterministic
  preference (platform_events over deliveries, newest first).
- Media poison pill: `loadDeliveryMedia` limit violations currently retry
  every 30s forever; they become `AttemptPermanentlyFailed`.
- Mirror ordering: deliveries are claimed per endpoint in
  `conversation_seq` order with single-flight per endpoint, so a retrying
  message cannot overtake its successors; a parked (outcome-unknown) head
  releases the lane after its budget.
- Mirror topology: endpoint-mode promotion loses its `platform='matrix'` /
  `platform='qq'` hardcoding; linking becomes an explicit
  platform-agnostic operation so a third mirror platform cannot recreate
  the 2f9b4da half-mirror.
- Dispatch claims stop impersonating OneBot `GroupMessage` with
  `"Matrix · alice"` smuggled through the nickname field; the claim carries
  the canonical envelope (principal, display, origin platform) directly.
- Delivery/dispatch workers move from 500ms polling to LISTEN/NOTIFY
  wakeups.

## Implementation and atomic rollout

The numbered slices below are implementation milestones, **not deployable
states**. No slice is released independently. Production moves directly
from the old content pipeline to the completed ADR in one maintenance-window
cutover, after all transports, entry points, migrations, cleanup, and tests
are ready. No production binary contains a v1/v2 dual reader, a dual writer,
or a legacy delivery fallback.

1. **IR core.** `Max.IR.Types` (phase-indexed tree, families, `Void`
   pruning) + `Max.IR.Lower` + plain emitter + bounded log digest emitter
   (`ForAllX LogDecor`) + property tests:
   `fallbackText` total; lowering monotone in caps (raising a tier never
   loses information); lowered output ⊆ caps-native node kinds; prompt
   codec round-trip (`parse . emit ≡ id` on mention/reply/sticker tokens);
   JSON instances exist for `Body 'Canonical` only.
2. **Ingest writes v2.** Adapters produce IR (QQ stops degrading faces/
   cards/media; Matrix/iMessage mention+reply fixes). Implement the offline
   v1 + segments → v2 backfill and rehearse it against a recent production
   snapshot. The final runtime codec accepts v2 only.
3. **Delivery reads IR — implement one transport at a time, Matrix first.**
   Claims carry IR + resolved reply + attribution; transports become
   emit-only. `renderedText`/`compatibilitySegments` leave the claim after
   the last transport is converted locally and before release; chunking,
   media budget, poison-pill, ordering, and `LIMIT 1` fixes land here. Local
   implementation order is Matrix (idempotent PUT — safest to iterate on),
   then OneBot (QQ + wechatpad), then iMessage, but none is deployed before
   all are complete. Lower notes persist to
   `message_deliveries.lower_notes`. The admin hydrated timeline may be
   implemented any time after slice 2; it is part of the same release.
4. **Bot outbound through IR.** ReplySend parses model tokens → IR;
   `enqueueOutbound` stores IR; `ConversationOutputCapabilities` replaced
   by `AdvertisedCaps`; one outbound path.
5. **wechatpad canonicalization.** Endpoint registration, envelope ingest,
   mirror fan-out, honest caps; legacy `insertGroupMessage` path retired.
6. **Meta-event mirroring + inbound completeness.** QQ recall/reaction
   parsing, capability-routed reactions in the outbox, edit/redact
   mirroring, forward chains as canonical children.
7. **Cleanup.** `rendered_text` becomes a regenerable prompt/search
   projection and `segments` frozen provenance; neither is readable by the
   delivery path. Dispatch is de-OneBot-ified and workers use
   LISTEN/NOTIFY. Delete the v1 runtime decoder, `ContentPart`, legacy
   wechatpad insertion, compatibility delivery branches, the superseded
   capability models, and the dead renderers (`matrixCanonicalText`,
   `renderOutbound`, `renderCanonicalText`, `attributedText`). Delete tests
   that assert removed implementation details; preserve every regression's
   semantic intent by rewriting it against ingest → canonical → lower →
   emit and the prompt codec.

### Definition of done

The release is ready only when all of the following hold:

- Every inbound adapter produces `InboundEnvelope` and `Body 'Ingest`, and
  every stored message has v2 `Body 'Canonical`; runtime code has no v1
  decoder.
- Every endpoint delivery follows canonical → `lower` → emit. Bot replies,
  proactive sends, mirrors, and admin-triggered sends enter that same path.
- Delivery claims contain neither `renderedText` nor
  `compatibilitySegments`, and delivery code cannot read `rendered_text` or
  `segments`.
- One capabilities decoder and one lowering/action-routing implementation
  govern all endpoints. Advertised native capabilities have emit contract
  tests; unsupported reactions are quiet no-ops.
- wechatpad is canonicalized; mention/reply/media ingest completeness and
  edit/redact/reaction mirroring are implemented; deterministic reply
  resolution, media poison-pill handling, endpoint ordering, generic mirror
  topology, canonical dispatch claims, and LISTEN/NOTIFY are complete.
- The old renderers, content types, entry points, compatibility branches,
  and tests that exist solely for them are gone. Historical regression
  cases remain, rewritten as final-pipeline tests.
- A fresh database can migrate to the final schema, and the backfill,
  integrity checks, smoke tests, and rollback procedure have all succeeded
  in a rehearsal using a recent production snapshot.

### Production cutover

This ADR intentionally requires a maintenance window:

The executable procedure, release gate, smoke matrix, and atomic rollback are
maintained in [the ADR 003 cutover runbook](../runbooks/adr003-cutover.md).

1. Close external ingress, drain delivery/dispatch workers to a known ledger
   state, and then stop the old service and all remaining writers.
2. Take and verify a restorable database snapshot.
3. Run the final schema migrations and offline v1 + segments → v2 backfill.
   Do not start the new application until it completes.
4. Run integrity checks: every `canonical_content` is valid v2, message and
   relation counts reconcile, delivery rows still reference valid messages
   and endpoints, and prompt/search projections can be regenerated.
5. Deploy the final binary and smoke-test representative QQ, Matrix,
   iMessage, and wechatpad ingress, prompt rendering, bot outbound, mirror
   delivery, meta-events, and echo reconciliation before reopening writes.
6. Resume workers and external ingress, then monitor permanent failures,
   parked deliveries, lower notes, and per-endpoint ordering.

Rollback is a single atomic boundary: stop the new service, restore the
pre-cutover database snapshot, and redeploy the old binary. Rolling back
only the binary is forbidden because the old application does not
understand v2. Backfill duration, table locks, snapshot time, and restore
time must be measured in rehearsal and included in the maintenance-window
budget.

## Consequences

- One representation to migrate, test, and reason about; write-time
  projections can drift from nothing because nothing else is stored.
- Adapters shrink to protocol IO plus a caps declaration; adding a platform
  means one `emit`, one `defaultCaps`, one inbound normalizer — no new
  degradation logic anywhere.
- The model contract is untouched, but its implementation becomes a codec
  over IR, so prompt fidelity and mirror fidelity can no longer diverge.
- The 049 ledger, lease/idempotency delivery machinery, and echo
  reconciliation are unchanged; this is a content-layer refactor.
- Cost: a full-table offline backfill, an explicit maintenance window, a
  snapshot-based rollback, and one coordinated change across every
  transport and content entry point. In return, production never serves a
  mixed content state and carries no transitional compatibility path.
