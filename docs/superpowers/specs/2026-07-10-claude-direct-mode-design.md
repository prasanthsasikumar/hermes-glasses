# Claude Direct Mode (Standalone — No Bridge)

**Date:** 2026-07-10
**Status:** Approved (user: laptop won't always be on; Apple voice accepted)

## Goal

The app talks straight to the Claude API — works on cellular with the Mac
off and no server anywhere. The bridge remains selectable for Hermes tasks
and the edge-tts voice.

## Design

- **Backend picker** in Settings: "Bridge (server)" vs "Claude Direct".
  Persisted; applies to new sessions.
- **`ClaudeDirectClient.swift`** — Messages API over URLSession
  (`x-api-key`, `anthropic-version: 2023-06-01`), model `claude-opus-4-8`
  (voice persona as prompt-cached system block, `max_tokens` 1024).
  Photos attach as base64 JPEG image blocks. Errors map to spoken-friendly
  messages.
- **API key in Keychain** (SecureField in Settings; never in UserDefaults
  or the repo).
- **On-device same-day history** (text-only, 40-message cap) — mirrors the
  bridge's semantics; New Chat clears it.
- **Visual triggers ported to Swift**: the bridge's keyword list, deictic
  pattern + stop-noun list, and 120 s photo-recency suppression. In direct
  mode the app captures locally and attaches — no capture_photo round trip.
- **Voice**: on-device `HermesSpeechSynthesizer` (already built). Settings
  note recommends downloading an iOS Premium voice.
- **Session flow** in direct mode: glasses session + mic + recognizer as
  today; the WebSocket bridge is never contacted. Barge-in, interrupt, and
  the test panel's Query/Visual buttons run through the same path.

## Out of scope

- Streaming token-by-token display; web-search tool; moving Hermes mode's
  behavior. Bridge modes unchanged.
