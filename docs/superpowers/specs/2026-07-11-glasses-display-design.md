# Glasses Display HUD — Design

**Date:** 2026-07-11
**Status:** Approved by user ("looks good")

## Goal

Show the Hermes voice loop on the Ray-Ban Display glasses' in-lens screen:
live transcript while the user speaks, status while the assistant thinks,
the reply as readable text with on-lens controls, and a blank lens when
idle. TTS keeps working as today, plus a silent mode where the on-lens
text replaces the spoken reply.

## Context

- User's glasses are the Meta Ray-Ban **Display** model (confirmed); the
  DAT SDK's `MWDATDisplay` module ships in the SDK version already in our
  package checkout — it just isn't linked by the app target yet.
- Display API: declarative view trees sent over `Display` capability on a
  `DeviceSession` (`addDisplay()`). Components: `FlexBox`, `Text`
  (`heading`/`body`/`meta`, `primary`/`secondary`), `Button`
  (primary/secondary/outline, icons, `onClick` callbacks that fire in the
  phone app), `Icon` (fixed set), `Image` (URI), `VideoPlayer` (mp4 URI).
  Each `send()` replaces the whole screen.
- Reference: `meta-wearables-dat-ios/samples/DisplayAccess` — uses
  `AutoDeviceSelector(filter: { $0.supportsDisplay() })`, a pending-action
  pattern (send auto-attaches, view fires when `DisplayState == .started`),
  and handles `DeviceSessionError.datAppOnTheGlassesUpdateRequired`.
- Requires Developer Mode in the Meta AI app; may require firmware or
  glasses-app updates (surfaced, not auto-handled).

## Decisions (user-confirmed)

1. Lens shows: reply text, live transcript, status indicators, on-lens
   controls — the full HUD loop.
2. Voice: keep TTS, add a **silent mode** toggle (text replaces voice).
3. Idle: **blank lens** — nothing rendered outside an active exchange.
4. Approach A (state-driven HUD) over reply-card-only (B) and an
   interactive conversation browser (C — YAGNI).

## Architecture

One new service plus one screens file:

- `HermesGlasses/Services/HermesDisplayManager.swift` — owns a persistent
  display `DeviceSession` (selector filtered on `supportsDisplay()`) and
  the `Display` capability, using the sample's pending-action pattern.
  Lifecycle: `start()` when a Hermes session starts (if the display
  feature toggle is on), `stop()` on session end. All public methods are
  non-blocking, best-effort: errors are logged via the existing debug
  channel and never propagate to the voice loop.
- `HermesGlasses/Services/HermesDisplayScreens.swift` — pure functions
  `(state) -> FlexBox`, no session state, unit-testable composition
  logic factored so text processing (truncation) is testable without the
  SDK.
- `HermesSessionViewModel` drives the manager at its existing state
  transitions; no new state machine.

Public surface of the manager:

```swift
func start() async            // create session, attach display
func stop()                   // detach + stop session
func showListening(partial: String)
func showThinking(query: String)
func showPhotoCaptured()
func showReply(text: String, speaking: Bool)
func clear()                  // blank the lens
var status: DisplayStatus     // .off, .connecting, .connected, .unavailable(String)
var onStop: (() -> Void)?     // on-lens button callbacks
var onRepeat: (() -> Void)?
var onNewChat: (() -> Void)?
```

New settings (UserDefaults, exposed in Settings):

- `display_hud_enabled` (Bool, default **true**) — "Glasses display".
- `display_silent_mode` (Bool, default **false**) — "Silent mode
  (read replies instead of hearing them)". Only takes effect while the
  display is attached; if the display is unavailable, TTS behaves as
  today so replies are never silently dropped.

## Screens

| State | Content |
|---|---|
| Listening | `meta` "Listening" + partial transcript as `body`. Nothing sent until the first partial arrives. |
| Thinking | The submitted question (`body`, `secondary`) + `meta` "Thinking…". |
| Photo | Camera icon + "Photo captured" (between capture and Thinking). |
| Reply | Reply text as `body` in a `.card`, truncated at 300 chars with "…". Button row: **Stop** (only while TTS playing), **Repeat**, **New chat**. |
| Blank | Empty `FlexBox`. If the SDK rejects an empty view, fallback: `display.stop()` to detach (re-attach on next show; the spike validates which works). |

Reply dwell (then blank):

- Spoken: TTS finish (or interrupt) + 8 s.
- Silent mode: reading time = `max(6 s, ceil(chars / 15) s)` from when the
  reply is shown.

## Data flow

Existing hooks → display calls:

- `onPartial` → `showListening(partial:)`, throttled: at most one send per
  400 ms; the finalized utterance always sends immediately.
- Query submitted → `showThinking(query:)`.
- Photo capture begins → `showPhotoCaptured()`.
- Response text arrives → `showReply(text:, speaking:)`. In silent mode
  (display attached) the TTS call is skipped for that turn, and the
  recognizer suspend/resume dance is skipped too (nothing to echo).
- TTS finished or interrupted → `showReply(text:, speaking: false)` and
  start the dwell timer; dwell expiry → `clear()`.
- New conversation → brief "New conversation" flash, then `clear()`.

On-lens buttons (callbacks run in the phone app):

- **Stop** → `interruptSpeech()`.
- **Repeat** → re-speak the last reply (or in silent mode, re-show with a
  fresh dwell).
- **New chat** → `startNewConversation()` + confirmation flash.

## Error handling

- Attach failure / `datAppOnTheGlassesUpdateRequired` / mid-session drop →
  log to debug, `status = .unavailable(reason)`, voice loop untouched.
  Retry happens naturally on the next session start.
- Every `send()` is wrapped; failures are logged and dropped.
- Settings → Glasses diagnostics gains a "Display" row: Connected /
  Connecting / Unavailable (reason, e.g. "glasses app update needed") /
  Off (toggle disabled).

## Known risk: session coexistence

`HermesCameraManager` creates a short-lived `DeviceSession` per photo; the
display needs a persistent one. Meta's samples never run two sessions at
once, so coexistence is unproven.

- **Spike (plan task 1):** on device, attach the display, send a test
  screen, then run a photo capture while the display session stays up.
- If concurrent sessions fail: refactor `HermesDisplayManager` and
  `HermesCameraManager` onto one shared `DeviceSession` (owned by a small
  session provider; capabilities added per feature). The screens, data
  flow, and manager API above are unchanged by this fallback.

## Testing

- Unit tests (plain Swift, no SDK): partial-send throttle, 300-char
  truncation, dwell computation (spoken vs silent), silent-mode gating
  (TTS skipped only when display attached + toggle on).
- On-device: new **Display** button in the test panel sends a static test
  screen through the full attach path (same pattern as Bridge/Sound/
  Photo/Query/Visual buttons); manual walk of the loop: speak → transcript
  on lens → Thinking → reply + buttons → dwell → blank; Stop/Repeat/New
  chat from the lens; silent mode end-to-end; display toggle off → no
  display traffic.

## Out of scope (YAGNI)

- Conversation history browsing / paging on the lens.
- Showing captured photos on the lens (Image takes URIs; local-photo
  serving is its own project).
- Video playback, idle-screen widgets (clock/weather), per-screen theming.
