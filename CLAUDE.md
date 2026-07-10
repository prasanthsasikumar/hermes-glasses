# Hermes Glasses — Audio Capture Bug (for Claude)

## What we're building
An iOS app that captures voice from Meta Ray-Ban glasses, streams audio via WebSocket to a Python bridge on a Mac (port 8765), which transcribes (Google STT) → asks Hermes Agent (`hermes chat -q`) → TTS (macOS `say`) → sends response back.

## Current state
- ✅ Xcode project builds for iOS (deployment target 17.0)
- ✅ Meta Wearables DAT SDK 0.8.0 integrated (SPM)
- ✅ Glasses registration/connection works (DAT DeviceSession reaches `.started`)
- ✅ WebSocket connection from phone → Mac bridge WORKS (confirmed in bridge logs)
- ✅ Python bridge works (tested locally on Mac)
- ✅ Hermes Agent chat works (`hermes chat -q "hello" --cli`)
- ❌ NO audio data reaches the Python bridge — connections open and close immediately
- ❌ Phone microphone light flashes briefly then the audio route switches to glasses and dies

## The core bug
`AVAudioEngine.inputNode.installTap()` is not delivering audio buffers. The app connects to the bridge but no audio chunks arrive. The WebSocket stays connected (the bridge sees connections) but closes without data.

## Key files
- `HermesGlasses/Services/HermesAudioManager.swift` — audio capture/playback
- `HermesGlasses/Services/HermesAPIClient.swift` — WebSocket client
- `HermesGlasses/ViewModels/HermesSessionViewModel.swift` — session orchestrator
- `bridge/hermes_bridge.py` — Python WebSocket bridge on Mac

## What we've tried
1. VAD threshold tuning (0.005–0.05) — no effect
2. Bypassing VAD entirely (sending ALL audio) — no effect
3. `setPreferredInput` to Bluetooth before activation — causes phone→glasses route switch that breaks tap
4. Waiting for Bluetooth route to stabilize before installing tap — still breaks
5. Using iPhone mic only (no Bluetooth) — STILL no audio

## Likely root causes (Claude should investigate)
1. **Microphone permission never requested!** `NSMicrophoneUsageDescription` is in Info.plist but `AVAudioSession.recordPermission` / `requestRecordPermission()` is NEVER called. The AVAudioEngine tap silently fails without permission.
2. The `startCapture()` method runs synchronously via `Thread.sleep()` on `@MainActor`, which blocks the main thread.
3. The audio session category/options might conflict with the DAT SDK's own audio management.
4. The `HermesAPIClient.connect()` uses a fragile continuation pattern that may cause the WebSocket to close prematurely.

## Project paths
```
~/Documents/github/hermes-glasses/
├── HermesGlasses.xcodeproj/
├── HermesGlasses/
│   ├── HermesGlassesApp.swift
│   ├── Info.plist
│   ├── HermesGlasses.entitlements
│   ├── Views/
│   │   ├── ContentView.swift
│   │   └── RegistrationView.swift
│   ├── ViewModels/
│   │   ├── WearablesViewModel.swift
│   │   └── HermesSessionViewModel.swift
│   └── Services/
│       ├── HermesAudioManager.swift
│       └── HermesAPIClient.swift
└── bridge/
    └── hermes_bridge.py
```

## How to build & deploy
```bash
cd ~/Documents/github/hermes-glasses
xcodebuild -project HermesGlasses.xcodeproj -scheme HermesGlasses \
  -destination 'platform=iOS,id=00008150-001410210C7A401C' build
APP_PATH="$HOME/Library/Developer/Xcode/DerivedData/HermesGlasses-*/Build/Products/Debug-iphoneos/Hermes Glasses.app"
xcrun devicectl device install app --device 00008150-001410210C7A401C "$APP_PATH"
xcrun devicectl device process launch --device 00008150-001410210C7A401C com.flowsxr.hermes-glasses
```

## How to run the bridge
```bash
cd ~/Documents/github/hermes-glasses/bridge
~/.hermes/hermes-agent/venv/bin/python hermes_bridge.py
# Logs to /tmp/hermes_bridge.log
# Listens on ws://0.0.0.0:8765/voice
```

## Bridge protocol
- App sends: binary PCM16 16kHz mono audio chunks
- App sends: `{"type":"end_of_audio"}` when done speaking
- Bridge sends: `{"type":"welcome"}` on connect
- Bridge sends: `{"type":"transcript","text":"..."}` after STT
- Bridge sends: `{"type":"response","text":"..."}` after Hermes responds
- Bridge sends: `{"type":"audio_start"}` / binary TTS data / `{"type":"audio_end"}`
- Bridge sends: `{"type":"error","message":"..."}` on errors

## What Claude should do
1. Add `AVAudioSession.requestRecordPermission()` before starting capture
2. Make `startCapture()` properly async (no `Thread.sleep` on main thread)
3. Simplify the `HermesAPIClient.connect()` — no continuation pattern, just a simple connect + wait
4. Test with iPhone mic first (don't try glasses Bluetooth routing yet)
5. Once audio flows to the bridge, then tackle glasses Bluetooth routing
