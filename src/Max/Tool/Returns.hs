-- | Model-facing result shapes, appended to tool descriptions so native calls
-- and code-mode programs can chain results without first inspecting them.
-- Descriptions are outside the schema hash, so this leaves grants and
-- workflow contracts unchanged. Keep each shape in step with its runner.
module Max.Tool.Returns (toolReturnType, withReturnType) where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)

withReturnType :: Text -> Text -> Text
withReturnType name description = maybe description (\shape -> description <> "\n返回：" <> shape) (toolReturnType name)

toolReturnType :: Text -> Maybe Text
toolReturnType name = Map.lookup name returnTypes

returnTypes :: Map Text Text
returnTypes =
  Map.fromList
    [ ("inspect_source", "{git_revision: string; bundle_hash: string; file_count: number; source_bytes: number} & ({action: \"search\"; query: string; results: {path: string; line: number; snippet: string}[]} | {action: \"read\"; path: string; start_line: number; end_line: number; total_lines: number; next_line: number | null; content: string} | {action: \"tree\"; path: string; files: string[]; truncated: boolean})"),
      ("context_search", "{query: string; semantic_used: boolean; results: {kind: \"message\" | \"episode\" | \"memory\"; ref: string; read: {ref: string}; source: string; score: number; time: string; snippet: string; pinned: boolean; permanent: boolean; match: {lexical: number | null; semantic: number | null}; principal_id?: string; message_id?: string; memory_id?: string}[]}"),
      ("context_read", "{items: (Msg | Memory)[]; prev: {cursor: string} | null; next: {cursor: string} | null; anchor?: string | null; episode?: {ref: string; start_cursor: string; end_cursor: string; state: string; source_hash_matches: boolean} | null; order?: \"ingest\" | \"forward_position\"}；Msg = {kind: \"message\"; ref: string; sender: {id: string; name: string}; received_at: string; occurred_at: string; text: string; text_offset: number; complete: boolean; more: {cursor: string} | null; reply_to: string | null; episode: string | null; forward: {ref: string} | null; message_kind: string; prompt_eligible: boolean; in_episode?: boolean}；Memory = {kind: \"memory\"; ref: string; text: string; version: string; lifecycle: string; subject: string; subject_id: string; updated_at: string; evidence: {kind: string; note: string | null; message: {ref: string} | null; episode: {ref: string} | null}[]}"),
      ("context_resume", "{handle: string; status: string; profile: string | null; started_at: string; finished_at: string | null; journal: {handle: string; kind: string; state: string; tool: string | null; arguments: unknown; failure: {code: string | null; detail: string | null}; result: unknown; result_preview: string | null; resume: {turn: string}}[]; request: {read: {ref: string}; text: string; complete: boolean}[]; outputs: {message_id: string; read: {ref: string}; preview: string}[]; outputs_has_older: boolean; has_more: boolean; next: {turn: string; after_cursor: number; limit: number} | null}；读 t#n:rm 或 call_id 时为 {handle: string; format: \"json_text\"; text: string; has_more: boolean; next: object | null}"),
      ("poke", "{ok: true}"),
      ("create_automation", "{ok: true; handle: string; trigger: \"time\" | \"message\" | \"webhook\"; next_fire?: string; recurring?: boolean; cron?: string | null; expires?: string; max_fires?: number; cooldown_seconds?: number; url?: string; bearer_token?: string; method?: \"POST\"; max_body_bytes?: number}"),
      ("list_automations", "{handle: string; instruction: string; trigger: \"time\" | \"message\" | \"webhook\"; next_fire: string | null; expires: string | null; fire_count: number; max_fires: number | null}[]"),
      ("cancel_automation", "{ok: true; revision: number; pending_policy: string; admitted_tasks_cancelled: boolean}"),
      ("update_automation", "{ok: true; revision: number; pending_policy: string; admitted_tasks_cancelled: boolean}"),
      ("automation_history", "{handle: string; revision: number; instruction: string; status: \"armed\" | \"fired\" | \"cancelled\" | \"expired\"; overlap: string; queue_limit: number; next_fire: string | null; fires: {fire_id: number; definition_revision: number; scheduled_at: string; disposition: string; task_id: number | null; coalesced_into: number | null; admission_state: \"pending\" | \"dispatched\"; evidence: string; last_error: string | null}[]}"),
      ("group_members", "{member_count: number; total_matched: number; offset: number; members: {id: number; name: string; platforms: string[]; role?: string; title?: string; qq?: string}[]; group_name?: string; group_avatar_url?: string; member_avatar_url_pattern?: string}"),
      ("view_avatar", "{attached: boolean; note: string}（图片附在下一条消息里）"),
      ("view_image", "{attached: number; total?: number; path?: string; note: string}（图片附在下一条消息里）"),
      ("view_video", "{attached: true; label: string; vision_tokens: number | null; note: string}（视频附在下一条消息里，label 写明时长、片段和倍速）"),
      ("memory_save", "{id: number; version: number}"),
      ("memory_update", "{id: number; version: number}"),
      ("memory_forget", "{ok: true; version: number}"),
      ("memory_list", "{id: number; content: string; version: number; lifecycle: string}[]"),
      ("pin_message", "{ok: true; pin_count: number}"),
      ("unpin_message", "{ok: true}"),
      ("task_start", "Task；Task = {task: string; objective: string; profile: string; owner: number; group_id: number; parent: string | null; status: string; progress: string | null; result: unknown; calls: number; model_rounds: number; usage: {model_calls: number; prompt_tokens: number; cached_prompt_tokens: number; completion_tokens: number; cost: {[currency: string]: number}; unpriced_calls: number}; created_at: string; finished_at: string | null; deadline: string}"),
      ("task_list", "Task[]（字段同 task_status）"),
      ("task_status", "{task: string; objective: string; profile: string; owner: number; group_id: number; parent: string | null; status: string; progress: string | null; result: unknown; calls: number; model_rounds: number; usage: {model_calls: number; prompt_tokens: number; cached_prompt_tokens: number; completion_tokens: number; cost: {[currency: string]: number}; unpriced_calls: number}; created_at: string; finished_at: string | null; deadline: string}"),
      ("task_steer", "{accepted: true}"),
      ("task_replace", "{accepted: true}"),
      ("task_cancel", "{accepted: true}"),
      ("task_wait", "{children: Task[]} | {feedback_pending: true}（Task 字段同 task_status）"),
      ("task_progress", "{recorded: true}"),
      ("use_skill", "{skill: string; loaded: string[]; already_loaded?: boolean; versions: {[name: string]: string}; availability: {skill: string; details: {tools: string[]; unavailable: string[]; reason?: string}}[]; instructions: string}"),
      ("view_bilibili", "{bvid: string; title: string; up: string; duration: string; pubdate: string; desc: string; stats: {view: number; like: number; coin: number; favorite: number; danmaku: number; reply: number; share: number}; top_comments: {user: string; likes: number; text: string}[] | string; parts?: number; video_attached: boolean; video_note?: string}"),
      ("sandbox_exec", "{exit_code: number; stdout: string; stderr: string; truncated: boolean; spill_truncated: boolean; full_output_file?: string}"),
      ("nix_search", "{results: string; truncated?: boolean; note?: string}"),
      ("sandbox_destroy", "{ok: true}"),
      ("read_file", "{content: string; bytes: number; truncated: boolean} | {binary: true; bytes_read: number; truncated: boolean}"),
      ("write_file", "{ok: true; bytes: number}"),
      ("send_image", "{ok: true; message_id: number}"),
      ("send_file", "{ok: true; name: string; message_id: number}"),
      ("find_stickers", "{hint: string; candidates: {id: number; desc: string}[]}"),
      ("web_search", "{answer: string | null; results: {title: string; url: string; snippet: string}[]}"),
      ("browser", "string：首行 \"Outcome: <action> ok|failed\"，第二行 \"Page: <url> | <title>\"，随后 Position/Note 行，\"Content:\" 之后是元素和正文；read 分页时 Note 含 \"read again with offset=N\""),
      ("view_zhihu", "string，格式同 browser"),
      ("run_code", "{value: unknown; exit: string; calls: {call: string; tool: string; outcome: string}[]; call_count: number; submitted_calls: number; omitted_calls: number; over_budget: boolean; run_ref: string}")
    ]
