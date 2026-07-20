# Settings Redesign + Voice Command Reference — Design

**Date:** 2026-07-20
**Status:** Implemented
**Source design:** claude.ai/design project `ad5d5d69-d923-460d-a1aa-1feb439bca7a`,
file `Settings Redesign.dc.html`, variant **1a** ("Native iOS, refined").

## Problem

Two things:

1. Settings had grown to one long scroll of eight sections. Adding the People
   feature made it worse.
2. Testers have no way to discover the spoken commands. The trigger phrases
   only existed inside the detectors.

## Design

### Settings as a hub

The single `Form` becomes a **hub of sub-pages**. The hub shows one row per
area, each carrying the value a tester most wants to see at a glance, plus a
glasses status card on top.

```
[status card]  Ray-Ban Display · Connected · Registered · 1 device   ›
Assistant                                               Claude      ›
Voice & Microphone                                      iPhone      ›
Glasses Display                                         On          ›
People                                                  On          ›
Navigation & Maps                                       On          ›
Context & Privacy                                       Sharing     ›
What can I say?                                                     ›
Developer                                        Test panel on      ›
```

Variant 1a (native) was chosen over 1b (custom warm palette + Space Grotesk):
1b is dark-only and would mean bundling a font and hand-rolling every control,
losing light mode, Dynamic Type, and native accessibility.

### Voice command reference

A new "What can I say?" page lists every spoken command: examples to read out
verbatim, a disclosure with the full phrase list, and which setting gates it.

The critical property: `VoiceCommandCatalog` reads the phrase lists **directly
out of the detectors** (`IntentDetector.navTriggers`, `.defineTriggers`,
`.rememberCommands`, `.cancelWords`, `.stopPhrases`, and
`VisualQueryDetector.keywords`). Those were `private static let`; they are now
internal. A tester-facing list that is hand-copied would drift the first time
someone adds a trigger — sourcing it from the detector makes drift impossible.

## Components

- **`VoiceCommandCatalog`** (new, Services): `VoiceCommandGroup` values built
  from the detectors. Fields: title, summary, examples, optional follow-up
  prose, phrases, gating setting name.
- **`SettingsView`** (new file, extracted from `ContentView.swift`): the hub
  plus eight private sub-pages — Glasses status, Assistant, Voice &
  Microphone, Glasses Display, People, Navigation & Maps, Context & Privacy,
  Developer — and the public `VoiceCommandsPage`.
- **`ContentView.swift`** loses its 300-line `SettingsView` (968 → 644 lines).
- **`MicSource.shortLabel`**: compact form for the hub row, where `label`'s
  parenthetical caveat doesn't fit.

## Behaviour preserved

- Typed values (bridge endpoint, provider API key) are still owned by the root
  `SettingsView` and committed on both Done and swipe-dismiss, so the existing
  "swipe-dismiss must not discard typed values" contract holds regardless of
  which sub-page is open.
- The bridge connection section is now shown only in Bridge mode, where it is
  the only mode it applies to.
- Every toggle, picker, preset action, and status readout carries over
  unchanged.

## Verification

Built for device and simulator; hub and command pages screenshotted on an
iPhone 17 Pro simulator. Existing `tests/intent` and `tests/encounters` suites
still pass (the detector lists only changed visibility).
