# Hermes Glasses

**Talk to Hermes AI from your Meta Ray-Ban glasses.**

An iOS app that connects to Meta Ray-Ban glasses via the [Meta Wearables DAT SDK](https://github.com/facebook/meta-wearables-dat-ios), captures your voice, streams it to Hermes Agent for real-time AI conversation, and plays the response back through your glasses.

## Architecture

```
┌─────────────────┐     Bluetooth      ┌──────────────┐     WebSocket      ┌──────────────┐
│  Meta Ray-Ban   │ ◄──────────────► │  iPhone App   │ ◄───────────────► │   Hermes     │
│    Glasses      │   Audio I/O      │ HermesGlasses │   Audio + JSON   │   Agent      │
└─────────────────┘                   └──────────────┘                   └──────────────┘
     Mic / Speaker                       AVAudioEngine                     STT → LLM → TTS
```

### Key Components

| File | Purpose |
|------|---------|
| `HermesGlassesApp.swift` | App entry point, DAT SDK config, URL callback handling |
| `ViewModels/WearablesViewModel.swift` | DAT SDK registration, device discovery, permissions |
| `ViewModels/HermesSessionViewModel.swift` | Orchestrates glasses session + Hermes API + audio |
| `Services/HermesAudioManager.swift` | Audio capture from glasses (VAD), TTS playback |
| `Services/HermesAPIClient.swift` | WebSocket client to Hermes Agent voice endpoint |
| `Views/ContentView.swift` | Main UI — conversation view, status, controls |
| `Views/RegistrationView.swift` | Meta AI registration flow overlay |

## Prerequisites

- **Xcode 16.0+** (or 15.0+)
- **iOS 17.0+** deployment target
- **Meta AI companion app** installed on your iPhone
- **Meta Ray-Ban glasses** paired with the Meta AI app
- **Developer Mode** enabled (Meta AI → Settings → Your glasses → Developer Mode)
- **Hermes Agent** running somewhere accessible (localhost, VPS, etc.)

## Quick Start

### 1. Open the project

```bash
cd ~/Documents/github/hermes-glasses
open HermesGlasses.xcodeproj
```

### 2. Configure your team

In Xcode:
- Select the **HermesGlasses** target
- Under **Signing & Capabilities**, select your Apple Developer team
- Change the bundle identifier if needed (default: `com.flowsxr.hermes-glasses`)

### 3. Set your Hermes endpoint

The app connects to Hermes Agent via WebSocket. Default endpoint:
```
ws://localhost:8765/voice
```

To change it:
- Launch the app (simulator or device)
- Tap the gear icon ⚙️ → Settings
- Enter your Hermes Agent WebSocket URL

For a Hermes Agent running on a VPS:
```
ws://your-server-ip:8765/voice
```

### 4. Build & run

Select your target device (or simulator) and hit **Run** (⌘R).

### 5. Connect your glasses

1. Tap **Connect Glasses** — this opens the Meta AI app
2. Follow the prompts in Meta AI to register Hermes Glasses
3. Once registered, tap **Start Hermes Session**
4. Speak to your glasses — Hermes will respond

## Hermes Agent Voice Protocol

The app speaks a simple WebSocket protocol. Your Hermes Agent needs to handle:

### Messages the app sends:

| Type | Format | When |
|------|--------|------|
| Audio chunk | Binary (PCM16, 16kHz mono) | User is speaking |
| End of audio | `{"type":"end_of_audio"}` | User stopped speaking |

### Messages Hermes should send:

| Type | Format | When |
|------|--------|------|
| Transcript | `{"type":"transcript","text":"..."}` | STT complete |
| Response text | `{"type":"response","text":"..."}` | Agent response ready |
| Audio start | `{"type":"audio_start"}` | Before TTS audio |
| TTS audio | Binary (PCM16, 24kHz mono) | TTS streaming |
| Audio end | `{"type":"audio_end"}` | TTS complete |
| Error | `{"type":"error","message":"..."}` | On error |

### Setting up the Hermes voice endpoint

You can use the Hermes Agent voice capabilities. Example using Hermes Agent:

```bash
# Start Hermes Agent with voice WebSocket enabled
hermes serve --voice-ws-port 8765
```

Or create a simple bridge using the Hermes Agent API. The app sends 16kHz PCM16 mono audio, so your endpoint needs to handle that format.

## Testing Without Glasses

Use MockDeviceKit for development without physical glasses:

1. Edit the scheme (⌘<)
2. Under **Run → Arguments**, add: `--mock-device`
3. Build and run

MockDeviceKit simulates glasses presence — you'll still need to handle audio separately (simulator doesn't have a real mic for glasses audio routing).

## Project Structure

```
hermes-glasses/
├── HermesGlasses.xcodeproj/
│   ├── project.pbxproj
│   └── xcshareddata/xcschemes/
│       └── HermesGlasses.xcscheme
├── HermesGlasses/
│   ├── HermesGlassesApp.swift          # @main entry point
│   ├── Info.plist                       # DAT SDK + permissions config
│   ├── HermesGlasses.entitlements       # Bluetooth + external accessory
│   ├── Assets.xcassets/
│   ├── Views/
│   │   ├── ContentView.swift            # Main UI
│   │   └── RegistrationView.swift       # Meta AI registration
│   ├── ViewModels/
│   │   ├── WearablesViewModel.swift     # DAT SDK device management
│   │   └── HermesSessionViewModel.swift # Hermes session orchestration
│   └── Services/
│       ├── HermesAudioManager.swift     # Bluetooth audio capture + TTS playback
│       └── HermesAPIClient.swift        # WebSocket client for Hermes
└── README.md
```

## Troubleshooting

### "Failed to configure Wearables SDK"
- Ensure the Meta AI app is installed
- Check that Developer Mode is enabled

### "Glasses app needs update"
- Update the Meta AI companion app
- Check for glasses firmware updates in Meta AI → Settings → Your glasses

### Audio not capturing from glasses
- Ensure Bluetooth is enabled
- Check that glasses are connected in Meta AI app
- Try restarting the glasses (fold/unfold)

### Hermes connection fails
- Verify Hermes Agent is running and port 8765 is accessible
- Check the endpoint URL in Settings
- For remote Hermes, ensure firewall allows the WebSocket port

## Dependencies

- [Meta Wearables DAT iOS SDK](https://github.com/facebook/meta-wearables-dat-ios) v0.8.0+ — via Swift Package Manager

## License

MIT
