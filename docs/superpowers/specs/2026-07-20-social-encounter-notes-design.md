# Social Encounter Notes — Design

**Date:** 2026-07-20
**Status:** Approved

## Problem

At a social gathering where the user meets many people, they want to quickly
capture, hands-free, a **photo of the person plus a short spoken note**, so that
at the end of the day they have a browsable list of pictures + notes on the
phone to make follow-ups easier.

## Goals

- Hands-free, per-person capture via a voice command mid-conversation.
- On-device only: no AI brain, no bridge, no network. Pure capture.
- Persistent storage that survives app restarts.
- A simple in-app review screen grouped by day, with edit/delete.

## Non-goals (v1)

- Export / share sheet, AI-generated summaries, face recognition.
- Retaining the raw audio clip (transcription text only).
- Saving to the iOS Photos library.

## User flow

1. User says **"remember this person"** (or: "remember him", "remember her",
   "remember them", "new contact", "note this person"). Classified by
   `IntentDetector` **before** the AI brain — never produces an AI reply.
2. The glasses capture a photo (`HermesCameraManager.capturePhoto`). The lens
   shows a "Speak your note" prompt; a short spoken cue ("Go ahead") plays,
   reusing the existing recognizer suspend/resume echo guard.
3. The **next finalized utterance** is the note. Existing pause detection
   finalizes it; the entry is saved. The user hears "Saved" and sees a ✓ flash
   on the lens.
4. Escape hatches, all best-effort so an encounter is never lost:
   - Saying "cancel" / "never mind" as the note → discard.
   - 30 s of silence → save the photo with an empty note (fill in later).
   - Camera failure → save the note with no photo.

## Architecture

New pieces, each with one responsibility:

- **`IntentDetector` (extend):** add a `.rememberPerson` case + trigger phrases.
  Ordered so it can't collide with the `define` ("what is") or navigation
  triggers.
- **`Encounter` model:** `id: UUID`, `note: String`, `timestamp: Date`,
  `photoFilename: String?`.
- **`EncounterStore` service:** persists to Application Support —
  `encounters/photos/<uuid>.jpg` for images and `encounters/encounters.json`
  for the index. Pure Foundation (Codable + FileManager), no database.
  API: `save(note:photo:)`, `all() -> [Encounter]`, `update(id:note:)`,
  `delete(id:)`, `photoData(for:) -> Data?`.
- **`HermesSessionViewModel` (extend):** an `awaitingEncounterNote` flag +
  `pendingEncounterPhoto`. When set, `submitQuery` routes the next utterance to
  the store instead of the AI. Handles the cancel word and the silence timeout.
- **`PeopleView` (new):** list grouped by day (Today / Yesterday / date),
  each row = photo thumbnail + note + time. Tap → detail with editable note;
  swipe → delete. Opened from a "People" button on the main screen.
- **Settings:** one toggle `social_notes_enabled` (default true), beside the
  navigation / definition-image toggles.

## Data flow

```
"remember this person"
   → IntentDetector.detect → .rememberPerson
   → VM: capture photo (best-effort), set awaitingEncounterNote,
         show "Speak your note", speak "Go ahead", start 30 s timer
   → next final utterance
       ├─ cancel word  → discard, clear state
       └─ otherwise    → EncounterStore.save(note, photo)
                         → "Saved" + ✓ flash, clear state
   (timeout) → EncounterStore.save(note: "", photo) → clear state
```

The `awaitingEncounterNote` branch sits at the very top of `submitQuery`, before
the existing `IntentDetector.detect` switch, so a note utterance is never
re-classified as navigation/define/AI.

## Error handling

- Camera permission missing / capture throws → proceed note-only; the entry is
  still created, photo `nil`. Consistent with the app's best-effort display
  philosophy.
- Store write failure → surface via the existing `show(_:)` error banner; the
  awaiting state is cleared so the app doesn't get stuck.
- Display/HUD calls stay best-effort (errors logged, never surfaced), matching
  the rest of the HUD code.

## Testing

- **`tests/intent/main.swift` (extend):** the new trigger phrases classify as
  `.rememberPerson`; "what is a person" / "remember when" style utterances do
  **not**; ordering vs navigation/define is correct.
- **`tests/encounters/main.swift` (new):** `EncounterStore` round-trip against a
  temp directory — save (with and without photo) → `all()` ordering →
  `update` → `delete` → `photoData`. Mirrors the style of the other
  `tests/*/main.swift` standalone harnesses.

## Settings keys

- `social_notes_enabled` (Bool, default true).
