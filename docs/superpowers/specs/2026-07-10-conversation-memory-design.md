# Conversation Memory, Voice Persona, Deictic Photo Triggers

**Date:** 2026-07-10
**Status:** Approved (session lifetime: same-day persistence + New Chat button)

## Goal

Fix the three UX failures from live testing: Hermes forgetting the previous
turn ("what drink?"), answering as a coding agent ("nothing in this
codebase"), and missing photo triggers for "this drink"-style references.

## Design

### 1. Same-day conversation memory (bridge)

- `hermes chat -Q` emits `session_id: <id>` on stderr; `--resume <id>`
  verifiably restores full conversation context (tested live).
- The bridge persists `{session_id, date}` to
  `~/.hermes_glasses_bridge_session.json`. A query resumes the stored
  session if its date is today; otherwise starts fresh. Sessions survive
  app reconnects and bridge restarts within the day.
- If a resume attempt fails (session pruned), the bridge clears the stored
  ID and retries once as a fresh session.

### 2. Voice-assistant persona

Every FRESH session's first query is prefixed with a persona preamble:
voice assistant on smart glasses, spoken answers, 1–3 sentences unless
asked, user may reference what they see. Resumed sessions don't repeat it.

### 3. Deictic photo triggers with recency suppression

- In addition to `VISUAL_KEYWORDS`, a deictic pattern triggers capture:
  `\b(this|that|these|those)\s+<word>` or "the one".
- Suppression: if a photo was captured on this connection within the last
  120 s, deictic-only triggers do NOT re-capture - session memory already
  holds the description. Explicit keywords ("look", "picture") always
  capture.

### 4. New Chat button (app)

- Toolbar button (square.and.pencil): sends `{"type":"new_session"}`.
- Bridge clears the stored session and replies `{"type":"session_reset"}`.
- App clears the on-screen conversation history on `session_reset`.

## Protocol additions

| Direction | Message | Meaning |
|---|---|---|
| app → bridge | `{"type":"new_session"}` | Forget conversation, start fresh |
| bridge → app | `{"type":"session_reset"}` | Confirmed; app clears its history |

## Interfaces

- `ask_hermes(text, image_path=None, resume=None) -> (reply, session_id)`
  (signature change; both may be None).
- `should_capture_photo(text, last_photo_at, now) -> bool`.
- `process_query(websocket, text, conn_state=None)`;
  `conn_state = {"last_photo_at": float}` per connection.

## Testing

Unit (stdlib unittest): session store date logic, session-ID extraction
from stderr, deictic matching, recency suppression, persona-prefix only on
fresh sessions. Existing process_query tests updated for the new
ask_hermes signature. On-device: the exact transcript that failed -
photo → "how do I make this drink" → follow-up - must now work.

## Out of scope

- Cross-day memory, multiple named conversations, voice-command reset.
