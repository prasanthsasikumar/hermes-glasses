# Navigation + Definition-with-picture on the HUD

Date: 2026-07-18
Status: Approved (design)

## Goal

Add two new on-device *intents* on top of the existing voice loop, both
surfacing on the Ray-Ban Display HUD:

1. **Navigation** — "take me to X" / "I want to go to X" brings up a map on
   the lens with the user's position marked and the route drawn, plus text
   directions underneath, and the map follows the user as they move.
2. **Definition with picture** — "what is X" speaks/writes the description as
   today *and* shows a picture of the subject on the lens.

Both are best-effort display features (like the current HUD): they light up
the lens when a Ray-Ban Display is attached and degrade gracefully otherwise.

## Hardware reality (the constraints that shape everything)

Confirmed against the Meta DAT SDK (`MWDATDisplay`, v0.8) and official docs:

- The glasses expose exactly two capabilities: **Display** (`addDisplay()`)
  and **Camera** (`addStream()`). There is **no** map / location / navigation
  capability.
- The Display renders a **declarative view tree** (`FlexBox`, `Text`, `Icon`,
  `Image`, `Button`, `VideoPlayer`) pushed over Bluetooth. Each `display.send`
  **replaces** the whole screen. There is no interactive/pannable map widget.
- `Image(uri:)` accepts **`https` URLs only** — no local file URLs, no
  `data:` base64 URIs. So any map picture must already live at an `https` URL.
- Display resolution is **600x600**; oversized or frequently-sent images lag
  because of Bluetooth bandwidth.

Consequence: a true interactive Apple/Google-Maps view is **not possible**.
The achievable experience is a **static map image that re-fetches and
re-sends as the user moves** — real map tiles, the user's pin, the route, and
text underneath — refreshing in steps rather than gliding.

## Decisions (from brainstorming)

- **Map behavior:** follows the user — re-center on current position and
  re-send every few seconds / on significant movement.
- **Map image provider:** **Mapbox Static Images API** (returns an `https`
  map image with markers + a GeoJSON/polyline route overlay). Needs a Mapbox
  access token.
- **Geocoding + routing:** **Apple MapKit** (`MKLocalSearch` + `MKDirections`)
  — free, no key. Mapbox is used *only* for the map picture.
- **Picture source (definition):** **Wikipedia / Wikimedia REST API** — free,
  no key, returns an `https` lead-image thumbnail; falls back to text-only
  when no image exists.
- **Nav is a command, not a question:** it skips the AI brain entirely and is
  handled on-device by MapKit.
- **Transport mode:** default walking; switch to driving when the phrase
  contains "drive"/"driving".
- **Refresh cadence:** ~every 4-5 s and only after the user has moved a
  meaningful distance, throttled against the Bluetooth budget.
- Both features are backend-agnostic (work in Direct and Bridge modes) because
  detection and rendering happen on the phone.

## Components

Each unit has one clear purpose and a small, testable surface.

### `IntentDetector` (pure, Foundation-only — unit-testable)
Mirrors the existing `VisualQueryDetector` style. Classifies a finalized
utterance into:
- `.navigate(destination: String, mode: TransportMode)`
- `.define(subject: String)`
- `.none`

and extracts the destination/subject substring.

- Nav triggers: "take me to", "navigate to", "directions to",
  "how do I get to", "I want to go to", "go to".
- Define triggers: "what is", "what's a", "what are", "tell me about".
- Trade-off: phrases like "I want to go to sleep" will extract "sleep" as a
  destination; the geocode simply fails and the app says it couldn't find a
  place. Acceptable; keeps detection cheap and on-device.

### `NavigationController` (`@MainActor`)
Owns a single active navigation session.
- `start(destination:mode:)`: resolve via `MKLocalSearch`, compute route +
  steps via `MKDirections`, begin CoreLocation updates.
- On each significant location update (throttled): choose the current step,
  build a Mapbox static-map URL centered on the user (pin + route + dest),
  call `displayManager.showNavigation(...)`.
- Speaks a short confirmation on start ("Navigating to X, N min") and each
  turn instruction.
- Ends on: lens **Stop** button, voice **"stop navigation"**, or **arrival**
  (within an arrival threshold of the destination).
- No route / geocode failure: speak a brief notice, show nothing intrusive.

### `MapboxStaticMap` (pure URL builder — unit-testable)
Given center, zoom, size (<= 600x600), a user marker, a destination marker,
an encoded route polyline, and the token → the Mapbox Static Images `https`
URL. No networking; pure string assembly so it unit-tests exactly.

### `WikipediaImageClient`
Given a subject string → optional `https` lead-image thumbnail via the
Wikimedia REST summary endpoint (sized to the display). Returns `nil` cleanly
when the page or image is missing. URL construction is unit-testable; the
network path is exercised manually.

### Display additions
New screen builders in `HermesDisplayScreens` (using `Image(uri:)`):
- `navigation(mapURL: String?, title: String, step: String, eta: String, onStop:)`
  — map image on top (or an arrow icon + step when no map URL), text below,
  Stop button.
- `definition(text: String, imageURL: String?)` — picture + description.

New methods on `HermesDisplayManager`: `showNavigation(...)`,
`showDefinition(...)`, reusing the existing throttled "newest-view-wins" send
queue.

### Settings
Following existing patterns (provider keys in Keychain, toggles in
`UserDefaults` mirrored on the view model):
- **Mapbox access token** stored in Keychain.
- Toggles: `navigation_enabled`, `definition_images_enabled` (default on).
- Surfaced in the existing Settings UI.

### ViewModel integration (`HermesSessionViewModel`)
- `submitQuery(_:)` consults `IntentDetector` first:
  - `.navigate` → hand to `NavigationController`, **do not** call the brain.
  - `.define` → run the normal reply path AND, in parallel, fetch the
    Wikipedia image; when both are ready, `showDefinition(text, imageURL)`.
  - `.none` → today's behavior.
- Wire `NavigationController`'s display + speech through the existing
  `displayManager` / `speechSynthesizer`, and its lens Stop button through the
  existing on-lens button callback plumbing.

## Data flow

**Navigation**
```
transcript "take me to X"
  -> IntentDetector -> .navigate(X, .walking)
  -> NavigationController.start
       -> MKLocalSearch(X) -> placemark
       -> MKDirections -> MKRoute (polyline + steps)
       -> speak "Navigating to X, N min"
       -> CoreLocation updates (throttled):
            pick current step
            MapboxStaticMap.url(center=user, pin=user, route, dest)
            displayManager.showNavigation(mapURL, title=X, step, eta)
       -> end on Stop button / "stop navigation" / arrival
```

**Definition**
```
transcript "what is X"
  -> IntentDetector -> .define(X)
  -> parallel:
       (a) normal reply path -> description text (+ TTS as today)
       (b) WikipediaImageClient.image(for: X) -> https thumbnail?
  -> when both ready: displayManager.showDefinition(text, imageURL)
```

## Error handling / degradation

- **No Mapbox token** → navigation shows text directions on the lens
  (arrow icon + step + ETA), no map tile, plus a one-time notice to add a
  token in Settings.
- **No display attached** → navigation speaks turn-by-turn; definition just
  speaks the answer (current behavior).
- **No Wikipedia image** → definition falls back to text/speech only.
- **Geocode fails / no route** → brief spoken notice; no crash, no intrusive
  screen.
- **Bluetooth lag** → map re-sends throttled (min interval + movement
  threshold), reusing the existing serialized send queue (newest wins).

## Testing

- `IntentDetector`: pure unit tests (phrases → intents + extracted args,
  including negatives), in the `tests/` Foundation-only style.
- `MapboxStaticMap`: pure unit tests (inputs → exact `https` URL).
- `WikipediaImageClient`: URL-construction unit tests; network path manual.
- Manual on-device verification of the full navigation and definition flows
  with the glasses.

## Out of scope (YAGNI)

- Interactive/pannable map, smooth camera-following (hardware can't).
- Re-routing logic beyond MapKit's initial route.
- Transit/cycling modes (walking + driving only for now).
- Hosting phone-rendered map snapshots (Mapbox URL avoids the need).
