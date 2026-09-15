# Source format notes

Trace treats agent session files as read-only, versionless external formats. Adapters accept unknown fields and skip unknown record types so agent upgrades do not stop an index run.

## Claude Code 2.1.270 baseline

- Default root: `~/.claude/projects`
- Session storage: append-only JSONL
- Important envelope fields: `type`, `uuid`, `sessionId`, `cwd`, `timestamp`, and `message`
- Message content may be a string or blocks including `text`, `thinking`, `tool_use`, and `tool_result`
- Usage lives on assistant messages and has distinct ordinary input, cache creation, cache read, and output counts
- Per-line UUIDs identify content records; the enclosing message/response ID deduplicates usage repeated across content-block lines

## Codex CLI 0.146.0 baseline

- Default root: dated rollout JSONL below `~/.codex/sessions`
- `session_meta` establishes session ID and working directory; `turn_context` supplies the active model and may update the working directory
- `response_item` carries messages, reasoning summaries, function calls, and function outputs
- `event_msg` carries failed or aborted turn state
- `token_usage_record` is retained raw and deduplicated by agent plus response ID for rollups
- Live task names come from `session_index.jsonl`; only the newest exact `state_<number>.sqlite` file is consulted as a read-only fallback. WAL/SHM files are not watched.

## Gemini CLI 0.46.0 baseline

- Default root: project directories below `~/.gemini/tmp`, with sessions under `chats`
- Legacy sessions are rewritten full JSON documents with a `messages` array and are scanned incrementally in bounded chunks
- Current sessions are append-style JSONL records whose `$set.messages` arrays can exceed one megabyte; metadata scanning accepts direct messages and nested arrays, including untyped text/content/output parts
- Trace scans message-object byte ranges inside each array. Hydration decodes only the selected message object, not the containing snapshot
- `tokens.thoughts` is separate billable output and is added at the model's configured reasoning/output rate

## Drift policy

Malformed individual records are skipped while complete neighboring records remain indexable. File-level read failures are surfaced in Source Health. Synthetic fixtures cover known variants, unknown fields, failures, duplicate usage, and both Gemini layouts; local real-corpus checks are opt-in through `TraceBench`.
