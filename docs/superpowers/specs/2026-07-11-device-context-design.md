# Device Context for Queries — Design

**Date:** 2026-07-11
**Status:** Approved by user ("Sounds good, go ahead with A")

## Goal

Every query carries a compact, current snapshot of the user's situation —
local time, location, motion, connectivity, phone battery, weather — so
Claude Direct and both bridges can answer "what time is it", "where am I",
"do I need a jacket", "am I online", "how much battery do I have" and use
the context implicitly everywhere else.

## Decisions (user-confirmed)

- Maximal context: exact coordinates AND area name, connectivity, battery,
  plus motion activity and current weather ("send as much information
  about me and my status as we can gather").
- Always attached (approach A) — not keyword-triggered, not tool-calling.
- Glasses battery is NOT available from the DAT SDK 0.8 (thermal/battery
  error states only) — phone battery only, stated limitation.

## Context line format

One line, segments joined by " · ", each segment omitted when unavailable:

```
Fri 11 Jul 2026, 3:42 PM (Pacific/Auckland) · Grafton, Auckland, NZ (-36.8605, 174.7645) · walking · online (Wi-Fi) · iPhone battery 25%, not charging · 14°C light rain
```

Segments, in order:

1. **Time** — `EEE d MMM yyyy, h:mm a (TimeZone.identifier)`, device
   locale-independent (en_US_POSIX day/month names). Always present.
2. **Location** — `<subLocality or locality>, <locality if distinct>,
   <ISO country> (<lat>, <lon> to 4 dp)`. Coordinates included only when
   the "precise location" sub-toggle is on; otherwise area name only.
   Omitted entirely when permission denied / no fix yet.
3. **Motion** — one of `stationary`, `walking`, `running`, `cycling`,
   `driving` from CMMotionActivity. Omitted when unknown/unavailable.
4. **Connectivity** — `online (Wi-Fi)`, `online (cellular)`, or `offline`.
5. **Battery** — `iPhone battery N%, charging|not charging`. Omitted if
   monitoring unavailable.
6. **Weather** — `<t>°C <condition>` from Open-Meteo current weather at
   the last known coordinates. Omitted when offline, no location, fetch
   failed, or cache older than 60 min.

## Architecture

New service `HermesGlasses/Services/DeviceContextProvider.swift`
(@MainActor class) + pure formatter in
`HermesGlasses/Services/DeviceContextFormatter.swift` (Foundation-only,
standalone-testable like HermesDisplayLogic).

- **Formatter** (`DeviceContextFormatter.contextLine(...)`): pure function
  taking optional typed inputs (date, timezone, placemark strings, coords,
  precision flag, activity, connectivity enum, battery, weather) →
  the exact line above. All omission logic lives here.
- **Provider** gathers inputs, all cached and non-blocking:
  - Location: `CLLocationManager` when-in-use; `requestLocation()` one-shot
    per query with a 60 s freshness cache; last fix retained. Reverse
    geocode via `CLGeocoder`, re-run only when moved > 200 m from the last
    geocoded fix (or none yet).
  - Connectivity: one `NWPathMonitor` running for the provider's lifetime.
  - Battery: `UIDevice.current.isBatteryMonitoringEnabled = true` at init;
    read level/state on demand.
  - Motion: `CMMotionActivityManager` live updates when available
    (`isActivityAvailable()`); silently absent otherwise (incl. simulator).
  - Weather: Open-Meteo `GET https://api.open-meteo.com/v1/forecast?
    latitude=&longitude=&current_weather=true` (no key), refreshed in the
    background when older than 15 min AND coordinates known AND online;
    WMO weather code mapped to a short phrase (subset table; unknown codes
    → omit condition, keep temperature).
  - `func contextLine() -> String?` returns synchronously from caches
    (never awaits sensors; kicks off background refreshes for stale
    pieces). Returns nil when the master toggle is off.
  - `func start()` / `stop()` tied to session start/end (location+motion
    updates only run during a session).

## Injection

In `submitQuery` (both branches), fetch `contextProvider.contextLine()`:

- **Claude Direct** (`ClaudeDirectClient.ask`): new optional
  `contextLine: String?` parameter. Sent as a SECOND system block
  `{"type":"text","text":"Current user context: <line>"}` appended after
  the persona block. The persona block keeps its `cache_control:
  ephemeral` (cache prefix unchanged); the context block is NOT cached.
  History stores raw user text only — old context never accumulates.
- **Bridge mode**: the app prepends `[Context: <line>]\n\n` to the query
  text in `sendQuery`. Works with BOTH existing bridges unmodified (Mac +
  maya); Hermes/Claude simply see it inline. `lastTranscript` and the
  conversation history keep the RAW text (no context prefix) so the phone
  UI shows what the user said.

## Permissions & privacy

- Info.plist additions: `NSLocationWhenInUseUsageDescription`,
  `NSMotionUsageDescription`.
- Location permission requested when a session starts with context
  enabled (not at app launch). Denied → location + weather segments
  omitted, everything else works.
- Settings → new "Context" section:
  - "Share my context" master toggle (`context_enabled`, default ON)
  - "Include precise coordinates" sub-toggle (`context_precise_location`,
    default ON per user's choice), disabled when master is off
  - A live preview row showing the exact current context line (or "Off").
- Weather calls go to open-meteo.com with bare coordinates — noted in the
  Settings footer.

## Error handling

Everything is best-effort and non-blocking: no context source may delay,
fail, or alter a query beyond the added line. Sensor errors are logged
(os.Logger, category "context") and the segment omitted. `contextLine()`
is synchronous — a query is never gated on GPS/geocode/weather I/O.

## Testing

- Standalone swiftc tests (pattern: tests/display-logic/) for the
  formatter: full line, each segment omitted, precise vs area-only
  location, WMO code mapping incl. unknown code, offline connectivity.
- On-device manual: Settings preview line populates; time/battery/network
  correct; location appears after permission grant; query "what time is
  it for me" answered with local time in both Claude Direct and bridge
  modes; toggle off → assistant no longer knows.

## Out of scope (noted for later)

- Calendar/reminders access ("what's on my calendar") — EventKit, own
  permission + serialization; separate project.
- Glasses battery (no SDK API).
- Tool-calling architecture.
