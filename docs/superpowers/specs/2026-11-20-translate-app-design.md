# Translate app - design

2026-11-20. Status: awaiting approval.

## Intent

Walk around, aim at a thing, and hear what it is called in a language you
picked. Aim at a banana with French selected and the phone says "banane";
with Chinese selected, "香蕉". Inspired by "Lisso" on the Ray-Ban Display
(the Reddit post could not be fetched, so this is built from the owner's
description, not from Lisso's behaviour).

The owner has no glasses to hand. The first version must be fully usable
with the iPhone camera (phone mode); the glasses path comes for free by
going through `hermesVM.vision`, and is unverified until hardware exists.

## Goals

- A new app, **Translate**, in the app registry: full-screen live camera,
  centre reticle, a language picker.
- Hold the reticle on an object the on-device detector knows -> the word
  is spoken at once in the selected language, offline, no AI call.
- Tap the camera view -> whatever is at the centre is sent to the AI,
  which names and translates it. This is the route for everything the
  detector does not know.
- The word is also shown: on the phone screen and on the lens (real or
  simulated), in native script, with a romanisation where the script is
  not Latin, and the English.
- Languages at launch: English, French, Chinese (Mandarin), Spanish.

## Non-goals

- Finger pointing / hand tracking. "Pointing" is aiming the reticle.
- A hands-free trigger for the AI path on glasses (button or spoken
  "what's this"). Tap is phone-only; add later with hardware to test on.
- A voice trigger to open the app.
- Saving words between sessions, vocabulary lists, export.
- Malayalam, or any language without a built-in iPhone voice. ElevenLabs
  is not used by this app.
- Translating text, signs, or sentences.

## Anti-goals

- Chatter. It must not repeat the same object while the reticle stays on
  it, and must not announce every passer-by.
- Silent AI spend. No AI call ever happens without a tap.
- A confident wrong word from the bundled table. The table is fixed data,
  reviewed once; if a label has no entry in a language the app says
  nothing rather than guessing.
- Starting the voice session. Like Lens, opening Translate must never
  leave the mic listening.

## Constraints (from the codebase)

- Camera lifecycle mirrors `LookupViewModel.start()/stop()`: read
  `visionRoute`, fall back to the phone if glasses are unreachable,
  `pinVisionRoute`, use `hermesVM.vision`, and when the stream is shared
  (`visionStreamIsShared`) observe it with `addVisionFrameObserver` under
  key `"translate"` instead of starting one. Never stop a stream it did
  not start.
- Detection reuses `ObjectDetector` (bundled `yolo11n`, 80 COCO labels)
  and `DwellTracker` (identity by IoU, post-snap cooldown).
- The AI call goes through `DirectClient.askOneShot` - never `ask()`, so
  nothing lands in conversation memory. It uses the direct provider and
  its key regardless of the selected backend, as the machine guide does.
- `HermesSpeechSynthesizer` holds ONE English voice today. Speaking
  "香蕉" with it does not work, so the synthesizer needs a per-utterance
  language.
- Lens output is a new `LensContent` case rendered by both
  `HermesDisplayScreens` and `SimulatedLensView`; never an SDK view tree
  from the feature.
- Only one of Lens / Lookup / conversation capture / Build Check may own
  a glasses stream. `ContentView.open` must refuse Translate during a
  Build Check run exactly as it refuses Lens and Lookup.
- New files are registered with `tools/pbx-register.py`.

## Approaches

**A. On-device only.** Detector label -> bundled translation table ->
iPhone voice. Instant, offline, free. Knows only 80 object types; silence
for everything else.

**B. AI for everything.** Centre of the frame goes to the AI on every
look. Names anything, and more precisely, but 1-2 s per word, needs a
signal, and costs money on every look of a walk.

**C. Both - chosen by the owner.** A for the 80 known objects; a tap
sends the centre to the AI for anything else. Instant where it can be,
never stuck where it can't. C is A plus one path, so A is built and
tested first.

## How it behaves

### Screen

```
+--------------------------------------+
| [x]   Translate          [Francais v]|   language picker (chips/menu)
|                                      |
|            live camera               |
|         .----------------.           |
|         |   [ banana ]   |           |   detector box under the reticle
|         |       (+)      |           |   reticle + hold-progress ring
|         '----------------'           |
|                                      |
|  Hold on an object - tap for anything else
| +----------------------------------+ |
| |  banane                    [>))] | |   result card: word, replay
| |  banana                          | |   English underneath
| +----------------------------------+ |
|  la chaise - le velo - la tasse      |   this session's words, newest first
+--------------------------------------+
```

For Chinese the card reads `香蕉` / `xiāngjiāo` / `banana`.

Built from `HermesDesign` primitives, full-screen with an explicit close
(it holds a live stream), modelled on `LookupView`.

### The instant path

1. Each frame goes to `ObjectDetector`; detections feed `DwellTracker`.
2. When the reticle has rested on one object for the dwell time, the
   label is looked up in the bundled table for the selected language.
3. Found: speak it, show the card, put it on the lens, add it to the
   session list. Not found: nothing happens.
4. Repeats are governed by a pure `TranslateSpeakPolicy` layered on top
   of the tracker (the tracker itself is shared with Lens and capture and
   is NOT changed): a detection must clear a speak confidence of 0.6, and
   the same word is not spoken again within 8 s of the last time it was
   spoken. The tracker's cooldown clears on a single missed frame, so
   without this a flickering box or a row of parked cars would chatter.
   Inside the quiet period the card still updates and the replay button
   still speaks; after it, looking back says the word again.

### The AI path

1. A tap on the camera view takes the current frame, cropped to the
   detector box under the reticle if there is one, otherwise to the
   centre of the frame.
2. The card shows "Looking..." and the lens shows the same.
3. `askOneShot` is called with a prompt asking for the single main object
   as JSON: its English name, the word in the target language, and a
   romanisation when the script is not Latin; or an explicit "nothing
   recognisable".
4. The reply is parsed by a pure parser. A word -> same outcome as the
   instant path. Nothing recognisable, a timeout, or a parse failure ->
   a line on the card ("Couldn't tell what that is"), nothing spoken.
5. No key / provider without vision -> the card says to add an AI key in
   Settings; the instant path keeps working.
6. One call in flight; taps while it runs are ignored.

### Speaking

- New `HermesSpeechSynthesizer.speak(_:language:)`: always the iPhone
  voice for that language (best installed quality), through the SAME
  queue so `onFinished` and recognizer suspension behave as for any cue.
  It skips ElevenLabs deliberately - a network fetch per word would undo
  the instant path, and the built-in voices cover all four languages.
- New `hermesVM.speakCue(_:language:)` with the existing rules: speaks
  when idle or listening (suspending the recognizer), dropped while
  Hermes is mid-answer.
- If the phone has no voice for the language, the word is still shown and
  a banner says the voice is missing.
- The replay button on the card speaks the last word again.

### Lens

New case `LensContent.translation(word:romanized:english:language:)`:
label = language name, body = the word, status line = romanisation and
English. Shown best-effort via a new `HermesDisplayManager` method, like
every display call.

## Parts

Pure, Foundation-only, each tested standalone in `tests/translate/`:

- `TranslateLanguage` - the four languages: id, display name, voice
  language code (`en-US`, `fr-FR`, `zh-CN`, `es-ES`), whether it needs a
  romanisation. Stored selection key: `translate_language`.
- `ObjectVocabulary` - the table: 80 detector labels x 4 languages ->
  word (+ pinyin for Chinese), or an explicit `silent` marker. Tests pin
  that every label the bundled model can emit is, in every language,
  either translated (non-empty) or deliberately silent - never missing.
  Labels take the sense the COCO dataset means: "mouse" is the computer
  mouse, "orange" the fruit, "remote" the TV remote, "tie" the necktie.
  Where one word is not safe across the objects a label covers, prefer
  the generic word ("cup" -> tasse / 杯子 / taza); if there is none, mark
  it silent. Spanish is Spain Spanish (`es-ES`). The table is written by
  the builder and has NOT been reviewed by a native speaker; the plan
  must produce it as one readable file the owner can hand to one.
- `TranslateSpeakPolicy` - confidence floor + same-word quiet period, as
  described under "The instant path". Time is passed in, so it is tested
  without a clock.
- `TranslateAnswerParser` - AI reply -> word / nothing / malformed.
  Tolerates code fences and surrounding prose.

Wiring:

- `TranslateViewModel` (camera lifecycle, dwell, tap, session list),
  `TranslateView`.
- `HermesApp` entry `translate`: capabilities `[.vision, .lens]`,
  `.fullScreen`, no voice groups, `requiresGlasses: false`; added to
  `newAppIDs`. `ContentView.open` case + Build Check refusal.
- `LensContent` case in both renderers; `tests/lens-content` and
  `tests/apps` extended.
- `CLAUDE.md` gains the invariants this adds.

## Calls made by the designer (not decided by the owner)

- **Spanish** added as a fourth language; "etc." was read as "a few
  common ones". Adding a language later = one table column + one enum
  case.
- **Default language: French.**
- **Dwell time 1.0 s** (Lens uses 2 s). Shorter suits walking; it is
  provisional until tried on a real walk.
- **`person` is skipped** on the instant path - otherwise a street is a
  stream of "personne". A tap still names a person generically.
- **Articles are not included** ("banane", not "la banane"), to keep the
  spoken word short. Gender can be added to the table later.
- **Chinese is Mandarin, Simplified, with tone-marked pinyin.**
- **Translate lands in the drawer**, after the existing apps, with the
  "New" dot; the pinned row is unchanged.
- **AI timeout 10 s.**
- **Session list is in memory only**, capped at 20.
- **Speak confidence 0.6** (the detector passes 0.4, fine for a log row
  but not for a word said aloud) and **8 s same-word quiet period**. Both
  provisional until tried on a walk.
- **The translation table is builder-written and unreviewed** by a
  native speaker; doubtful entries are left silent rather than guessed.

## Left to the builder

- Exact layout, picker control (chips vs menu), and animation.
- The AI prompt wording and JPEG size/quality for the crop.
- The size of the centre crop when no box is under the reticle.
- Confirming the model's exact label strings ("cell phone", "potted
  plant", "tv", ...) from the bundled `yolo11n.mlpackage` and pinning
  them in the test.
- Whether `TranslateViewModel` shares helper code with
  `LookupViewModel` or mirrors it.

## Verification

- Standalone suites: `tests/translate`, `tests/apps`,
  `tests/lens-content`, plus every existing suite.
- `xcodebuild` for generic iOS.
- On an iPhone, phone mode: instant path on a handful of known objects in
  each language; tap path on an unknown object; no-key behaviour; replay;
  opening and closing leaves no mic or camera running.
- NOT verifiable now: the glasses camera path and the real lens card.
  Say so plainly in the hand-back.
