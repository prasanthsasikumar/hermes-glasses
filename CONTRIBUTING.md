# Contributing to Hermes Glasses

Thanks for your interest! This project has two parts: a SwiftUI iOS app
(`HermesGlasses/`) and a Python WebSocket bridge (`bridge/`).

## Build & test

**iOS app**

```bash
xcodebuild -project HermesGlasses.xcodeproj -scheme HermesGlasses \
  -destination 'generic/platform=iOS' build
```

**Provider unit tests** (standalone, no XCTest target)

```bash
xcrun swiftc \
  HermesGlasses/Services/Providers/AIProvider.swift \
  HermesGlasses/Services/Providers/AnthropicProvider.swift \
  HermesGlasses/Services/Providers/OpenAICompatibleProvider.swift \
  HermesGlasses/Services/Providers/GeminiProvider.swift \
  tests/providers/main.swift -o /tmp/provider-tests && /tmp/provider-tests
```

Other standalone suites live under `tests/` (`device-context`, `display-logic`)
and follow the same `swiftc <source> tests/<x>/main.swift` pattern.

**Bridge**

```bash
cd bridge && python -m unittest test_hermes_bridge -v
```

## Adding an AI provider

Direct mode is a small seam. To add a provider:

1. Add a type conforming to `AIProvider` in `HermesGlasses/Services/Providers/`
   (pure Foundation — no `os`/SwiftUI, so it stays swiftc-testable).
2. Register it in `AIProviderRegistry.all` (`AIProvider.swift`).
3. Add tests to `tests/providers/main.swift` for `buildRequest` / `parseReply`.

That's it — the Settings UI and orchestration are provider-agnostic.

## Conventions

- Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`, `refactor:`).
- TDD: write the failing test first.
- Never commit secrets or personal network addresses.
