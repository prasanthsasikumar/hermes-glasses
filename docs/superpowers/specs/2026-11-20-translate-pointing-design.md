# Translate: finger pointing and phrases - design

2026-11-20. Status: awaiting approval. Builds on
`2026-11-20-translate-app-design.md` (already built, branch
`translate-app`); read that first.

## Intent

The owner is in China next week with the iPhone (no glasses). They want
to point a FINGER at a thing and hear its Chinese name, then have a few
ready phrases to use on a shopkeeper ("How much is this?").

Today "pointing" means aiming the centre reticle, and only a tap reaches
the AI. This adds a finger as a second, stronger way of saying "that
one", and a small phrasebook.

## Goals

- When a pointing hand is in the frame, the target is what the index
  finger points at, not the centre reticle.
- Pointed-at thing is one of the detector's 80 objects -> the word is
  spoken at once, on-device, as today.
- Pointed-at thing is anything else -> a crop of that spot goes to the
  AI provider AUTOMATICALLY after the finger has held still. (Owner's
  decision: a held finger is as deliberate as a tap.)
- No finger in the frame -> everything behaves exactly as it does today.
- A fixed set of phrases, bundled and offline, shown as buttons; tapping
  one speaks it in the selected language and shows it large enough to
  hold up to someone.

## Non-goals

- MediaPipe or any new dependency. iOS Vision's hand pose
  (`VNDetectHumanHandPoseRequest`) gives the index finger joints
  on-device.
- AI-written, object-specific phrases ("Is this spicy?"). Approach C
  below; can be added later on top of this.
- Listening to the shopkeeper's answer and translating it back.
- Two hands, gestures other than an index-finger point, depth.
- A hands-free phrase trigger on glasses.

## Anti-goals

- Silent AI spend. The rule changes from "no tap, no call" to "no tap
  and no held pointing finger, no call". A hand that is merely in view -
  open palm, a fist, carrying a bag - must never send anything.
- Repeat sends. One hold = one request. Keeping the finger on the same
  thing must not send again.
- Hammering a dead network. In China the providers are mostly
  unreachable without roaming or a VPN; a failed or keyless call must
  not be retried by itself in a loop.
- The finger named instead of the object.
- Breaking the no-finger behaviour that already works.

## Constraints (from the codebase)

- `DwellTracker` has a fixed centre reticle and is shared with Lens and
  conversation capture. It is NOT changed. The pointing path has its own
  small pure tracker.
- `ObjectDetector` runs Vision with `orientation: .up` on the frame's
  pixel buffer and converts to top-left-origin normalised boxes once.
  The hand detector must run on the same buffer with the same
  orientation and convert the same way, so fingertip and boxes share one
  coordinate space.
- The hand is part of a `person` detection; `person` is already skipped
  (`ObjectVocabulary.skippedLabels`), so the hand's owner never becomes
  the target.
- AI calls stay on `DirectClient.askOneShot`, one in flight, language
  captured at send time, `finishTap`'s `didStop` guard kept.
- Speech stays on `speakCue(_:language:)` (iPhone voice, never
  ElevenLabs).
- New files via `tools/pbx-register.py`; pure logic Foundation-only with
  tests in `tests/translate/`.
- CLAUDE.md's "No tap, no call" bullet must be rewritten to match.

## Approaches

**A. Finger picks the target; phone answers when it can, AI when it
can't; fixed offline phrases - chosen by the owner.** Still useful with
no connection. Phrases are generic.

**B. Finger always goes to the AI, which also writes the phrases.**
Better names and tailored phrases; every point costs a request and 1-2
s, and none of it works in China without roaming.

**C. A, plus AI-added phrases when reachable.** Most capable, most to go
wrong a week before the trip. Can be layered on A later.

## How it behaves

### Finding the finger

Each frame (throttled, about 10 per second) goes to a hand-pose request
for ONE hand. A hand counts as POINTING only when:

- the index finger's tip, DIP, PIP and MCP joints are all found with
  confidence >= 0.5;
- the index finger is extended (roughly straight); and
- the middle finger is NOT extended (curled, or not confidently found).

That last test is what keeps an open palm from being a point. From a
pointing hand: `tip` = index tip, `direction` = unit vector from index
PIP to index tip.

### Choosing the target

- `probe` = `tip + direction * 0.06` (just past the fingertip; all
  distances are fractions of the frame).
- Target box = the speakable detection containing `probe`; if none, the
  first speakable detection the ray from `tip` along `direction` enters
  within 0.35. Several candidates -> the one entered first.
- A box covering more than 0.35 of the frame is never a finger target.
  A stall's table or counter is one huge `dining table` box; without
  this, pointing at an unknown thing ON it would say "table" and never
  reach the AI. Among several boxes containing the probe, the smallest
  wins. (The centre-reticle path is unchanged.)
- No box -> the target is a REGION: a square of side 0.4 centred at
  `tip + direction * 0.15`, clamped to the frame. This is what the AI
  sees; it includes the fingertip on purpose so the AI can tell which
  thing is meant.

### Holding

A pure `PointHold` tracker (time passed in, like the others):

- the point is "held" while the probe stays within 0.05 of where the
  hold began; moving further restarts the hold;
- after 1.0 s held it FIRES once, with the target at that moment;
- it then stays spent until the probe has moved more than 0.12 from the
  firing position, or no pointing hand has been seen for 1.0 s;
- a pointing hand lost for less than 0.3 s does not reset a hold (pose
  detection flickers).

On fire:

- target is a box with a word in the current language and detector
  confidence >= 0.6 -> the instant word: card, lens, voice. The 8 s
  same-word quiet period does NOT apply (the user pointed; like replay).
- otherwise -> the automatic AI send, subject to the guards below. A box
  under the 0.6 floor is sent as its box crop, not spoken as a guess.

### The automatic AI send

Same call, parser, card states and lens states as the tap path. Extra
guards, because nobody tapped:

- one call in flight (shared with tap);
- at least 3 s between automatic sends;
- a hold that fires while either of those two blocks it is NOT spent:
  the hold restarts, so a finger still resting there sends as soon as
  the guard clears. A hold whose send actually went out IS spent,
  whatever the outcome - a failure is never retried on the same hold;
- after a missing-key, rejected-key (401/403) or no-vision-provider
  error, automatic sends are OFF until the screen is reopened; the card
  shows the existing message. Tap still tries.
- after any other failure (timeout, no network) the card shows "Couldn't
  reach the AI" and the next automatic send needs a new hold as usual -
  no automatic retry.

The prompt gains one line when a finger chose the crop: a finger may be
visible, name the object it points at, never the hand or finger.

A TAP while a pointing hand is in view sends the finger's target (box or
region) instead of the centre. With no hand it is unchanged.

### Phone camera only, for now

Finger pointing runs only on the iPhone-camera route. On the glasses
route the hand request is not run and the Finger toggle is hidden: the
wearer's own hands are in view all day, a relaxed index finger is a
common resting shape, and an untested path that can send paid requests
is the silent-spend anti-goal. Enabling it on glasses is a later change,
made with glasses to test on.

### No finger

Reticle dwell, speak policy, tap: unchanged. While a pointing hand IS in
view the centre-reticle dwell is paused (and flushed), so the reticle
and the finger never both speak.

### Phrases

A bundled table, `TranslatePhrases`, six phrases x four languages, with
pinyin for Chinese:

| English | 中文 | pinyin |
|---|---|---|
| What is this? | 这是什么？ | zhè shì shénme |
| How much is this? | 这个多少钱？ | zhège duōshao qián |
| I'd like this one | 我要这个 | wǒ yào zhège |
| Too expensive | 太贵了 | tài guì le |
| Can it be cheaper? | 可以便宜一点吗？ | kěyǐ piányi yìdiǎn ma |
| No, thank you | 不要，谢谢 | búyào, xièxie |

(French and Spanish columns written by the builder in the same style.)

Shown as a horizontally scrolling row of buttons labelled in ENGLISH
under the result card, whenever the camera is running - not only after a
word, so "What is this?" is usable before anything is recognised. Hidden
when the selected language is English. Tapping one: speaks it in the
selected language, and the card shows the phrase large (native script,
pinyin, English) so the phone can be held up. It also goes to the lens
card. Phrases are not added to the recent-words strip and never call the
AI.

A phrase PINS the card: turning the phone towards a shopkeeper aims the
camera at new things, and a word replacing the phrase mid-read would
defeat it. While pinned, the reticle dwell and the finger are paused
(holds flushed), taps on the camera are ignored, and an AI answer that
lands is added to the recent strip without taking the card or speaking.
The pin ends when the user taps the card's close button, taps another
phrase (which pins that one), or after 20 s. The card then shows
whatever word was there before. Replay speaks what the card shows.

### Screen

```
|            live camera               |
|        o  <- probe ring + hold ring  |
|       /                              |
|     (finger)        ( + ) dimmed     |   centre reticle dims while pointing
|                                      |
|  Point at something - or hold the circle on it
| +----------------------------------+ |
| |  香蕉                       [>))] | |
| |  xiāngjiāo · banana              | |
| +----------------------------------+ |
| [What is this?] [How much is this?] [I'd like…]  ->
|  椅子 · 自行车 · 杯子                   |
```

A small "Finger" toggle chip in the header area, default on, persisted
as `translate_finger_enabled`. Off = today's behaviour exactly, and the
hand request is not run at all.

## Parts

Pure, Foundation-only (CoreGraphics types as the existing pure files
use), tested in `tests/translate/`:

- `FingerPointer` - joints in, `Pointing(tip, direction)?` out: the
  pointing test; plus target selection (`probe`, box choice, region).
- `PointHold` - the hold / fire-once / re-arm tracker.
- `TranslatePhrases` - the table; test pins every phrase present and
  non-empty in every language, pinyin present for Chinese.
- `TranslatePrompt` - the pointing line.

Wiring:

- `HandPoseDetector` - wraps the Vision request, throttles, converts
  coordinates once, hands joints to the main actor. Mirrors
  `ObjectDetector`'s shape.
- `TranslateViewModel` - runs it beside the object detector, owns the
  `PointHold`, the automatic-send guards and the phrase action.
- `TranslateView` - fingertip/probe overlay, phrase row, toggle.
- CLAUDE.md invariants updated.

## Calls made by the designer (not decided by the owner)

- Apple Vision hand pose instead of MediaPipe.
- Index finger only; middle-finger-curled as the "this is a point" test.
- All the numbers above (0.5 joint confidence, 0.06 probe, 0.35 reach,
  0.4 region, 0.15 region offset, 1.0 s hold, 0.05 / 0.12 movement, 0.3 s
  / 1.0 s loss, 3 s between sends, ~10 pose frames per second). All
  PROVISIONAL: none can be tuned without a person pointing at things.
- A pointed-at known object skips the 8 s quiet period.
- Auto-send switches itself off after a key/provider error.
- The six phrases and their wording; hidden in English mode; buttons
  labelled in English.
- A phrase takes over the card and lens until the next word.
- The Finger toggle, default on.
- Boxes over 0.35 of the frame are ignored by the finger; smallest box
  wins.
- A phrase pins the card and pauses recognition until closed or 20 s.
- Finger pointing is phone-camera only until glasses can be tested.
- A hold blocked by a guard restarts rather than being spent.
- Tap follows the finger when one is pointing.

## Left to the builder

- How "extended" and "curled" are computed from the joints, provided the
  tests pin: a straight index with curled middle points; an open palm, a
  fist and a two-finger "peace" hand do not.
- Overlay drawing and animation; exact wording of status lines.
- Whether the hand request shares a handler with the object request or
  runs separately.
- French and Spanish phrase wording.

## Verification

- Standalone suites (`tests/translate` extended, all existing suites),
  `xcodebuild` generic iOS and the owner's iPhone.
- On the iPhone, by the owner: point at a known object; point at an
  unknown one with a key and a connection; open palm in view sends
  nothing; holding still sends once; airplane mode shows the failure
  once and does not loop; each phrase speaks; Finger off = old behaviour.
- NOT verifiable by the builder: whether pointing picks the right thing
  in practice, every threshold, the glasses camera view of a hand, and
  the phrase wording by a native speaker. Say so in the hand-back.

## Amendment (2026-11-20, after the owner tried it)

Two things changed on the owner's instruction; where this section and
the text above disagree, this section wins.

- **Finger on = finger only.** The centre reticle is off for as long as
  the Finger switch is on, not merely while a hand is in view. The app
  was naming whatever sat in front of the camera.
- **AI first, whole frame.** A held point sends the whole frame to the
  AI; the detector is no longer asked first, and no fingertip crop is
  made. Pointing at a toolbox had produced "keyboard" (the detector,
  forcing it into one of its 80 classes) and then "card reader" (the AI,
  shown a tight crop with no context). The detector's word is now only a
  fallback when the AI cannot be reached or is not set up, labelled as
  the phone's own guess.
- Consequence: with Finger on, every point is one AI request and takes a
  second or two, and with no connection the answer is at best the
  detector's guess after the 10 s timeout.
