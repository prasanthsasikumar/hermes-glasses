# Provider abstraction & public-readiness — design

Date: 2026-07-11

## Goal

Make Hermes Glasses a clean, professional public repository where anyone can
**bring their own AI provider** — Claude, OpenAI, Gemini, or a local model
(Ollama) — with a paste-your-key onboarding, *or* run the full Hermes agent via
the bridge. Today "direct mode" is hardcoded to Anthropic and the README only
teaches the Hermes-bridge path, which requires infrastructure most people won't
have on first run.

## Non-goals

- No new UI surfaces beyond a generalized provider section in Settings.
- No streaming responses (current design is single-shot request/response).
- No per-provider tool/function-calling — direct mode stays a plain
  chat+vision call; the agentic path remains the Hermes bridge.
- No secrets or provider keys ever committed; keys live only in the Keychain
  (app) or environment (bridge).

## Workstreams

Two independent workstreams, executed in order:

- **A — Provider abstraction** (core feature). The "connect your own API" work.
- **B — Public-readiness cleanup** (docs + hygiene). Partly depends on A because
  the README's onboarding narrative describes the provider UX from A.

---

## Workstream A — Provider abstraction

### Current state

- `AssistantBackend` enum: `.bridge | .claudeDirect`
  (`HermesSessionViewModel.swift`).
- `ClaudeDirectClient` is Anthropic-specific: fixed endpoint
  `https://api.anthropic.com/v1/messages`, `x-api-key` + `anthropic-version`
  headers, `ClaudeModel` enum, Keychain account `anthropic_api_key`, request
  body shaped as Anthropic Messages (system blocks, base64 image blocks).
- Shared, provider-agnostic logic already lives alongside it: same-day history
  (UserDefaults), `VisualQueryDetector`, the system prompt, the context line.
- Settings UI (`ContentView.swift` `SettingsView`): Backend picker; when
  `.claudeDirect`, a `ClaudeModel` picker + API-key `SecureField` + key status.
- Bridge (`hermes_bridge.py`): `BRAIN=hermes|claude` env var; the `claude`
  brain uses the `anthropic` Python SDK.

### Design

**`AIProvider` protocol** (new, `HermesGlasses/Services/Providers/`):

```
protocol AIProvider {
    var id: String { get }                 // stable key: "anthropic", "openai", "gemini", "ollama"
    var displayName: String { get }        // "Claude", "OpenAI", "Gemini", "Local (Ollama)"
    var defaultBaseURL: String { get }
    var allowsCustomBaseURL: Bool { get }  // true for openai/ollama-style proxies
    var requiresKey: Bool { get }          // false for local Ollama
    var supportsVision: Bool { get }
    var curatedModels: [ModelOption] { get } // suggested models; UI also allows free-text

    func buildRequest(system: String, contextLine: String?, history: [Turn],
                      userText: String, imageJPEG: Data?, model: String,
                      baseURL: String, apiKey: String?) throws -> URLRequest
    func parseReply(_ data: Data, status: Int) throws -> String
}
```

`buildRequest` and `parseReply` are **pure** given their inputs (no globals) →
directly unit-testable.

**Concrete providers — three request shapes:**

- `AnthropicProvider` — Messages API. Refactor the existing `ClaudeDirectClient`
  body/parse logic into here unchanged (system as cached-first block + per-query
  context block, base64 image blocks, `x-api-key`/`anthropic-version`).
- `OpenAICompatibleProvider` — `POST {base}/v1/chat/completions`,
  `Authorization: Bearer <key>`, messages with array content and `image_url`
  data-URIs for vision. **One implementation serves OpenAI, Ollama, and any
  OpenAI-style proxy** (LM Studio, Groq, OpenRouter) via base-URL override.
  - "OpenAI" preset: `defaultBaseURL=https://api.openai.com`, `requiresKey=true`.
  - "Local (Ollama)" preset: `defaultBaseURL=http://localhost:11434`,
    `requiresKey=false`, `allowsCustomBaseURL=true`. Ollama exposes an
    OpenAI-compatible `/v1/chat/completions`, so it reuses this provider.
- `GeminiProvider` — `POST {base}/v1beta/models/{model}:generateContent?key=`,
  `contents`/`parts` with `inline_data` for vision.

**Keychain per provider:** account = `"<provider-id>_api_key"`. Users can store
several keys and switch providers without re-entering. `requiresKey=false`
providers skip the key entirely.

**Selection state** (UserDefaults): `direct_provider_id` (default `anthropic`),
`direct_model` (per-provider default), `direct_base_url_<id>` (when custom URL
is allowed).

**Client rename & wiring:**

- `.claudeDirect` → `.direct` in `AssistantBackend` (label "Direct (your API)").
  Migrate any persisted `"claudeDirect"` raw value to `"direct"` on load.
- `ClaudeDirectClient` → `DirectClient`: owns provider lookup by id, shared
  history, `VisualQueryDetector`, system prompt, and the `ask(...)` orchestration
  (resolve provider → resolve model/baseURL/key → `buildRequest` → send →
  `parseReply` → persist history). `ClaudeModel` enum is removed; models come
  from each provider's `curatedModels` plus free-text.
- Call sites in `HermesSessionViewModel` that switch on `.claudeDirect` update to
  `.direct`; `setClaudeKey` → `setProviderKey(id:key:)`; `hasClaudeKey` →
  `hasKey(for:)`.

**Settings UI** (generalize the Assistant section):

```
Backend:  [ Direct (your API) | Bridge (server) ]
── Direct ──
Provider: [ Claude | OpenAI | Gemini | Local (Ollama) ]
Base URL: [ ...................... ]   (only when allowsCustomBaseURL)
Model:    [ picker of curatedModels + "Custom…" free-text ]
API key:  [ SecureField ]              (hidden when requiresKey == false)
Key status: Saved in Keychain / Not set
```

**Bridge** (`hermes_bridge.py`): generalize `BRAIN=hermes|claude` →
`hermes|anthropic|openai|gemini`, mirroring the app's provider set. Add
`HERMES_BRIDGE_BASE_URL` (OpenAI/Ollama) and reuse existing `HERMES_BRIDGE_MODEL`.
`hermes` remains the default agentic path. This keeps app and bridge symmetric.

### Testing (TDD)

- New `tests/providers/main.swift` (standalone, matching the existing
  `tests/device-context` / `tests/display-logic` pattern): for each provider,
  assert `buildRequest` produces the expected URL, headers, and JSON body (with
  and without an image) and `parseReply` extracts text from a canned success
  body and surfaces the error message from a canned error body.
- `test_hermes_bridge.py`: add cases for the new brains' request shaping /
  response parsing (mock the HTTP layer).
- Tests written before implementation for each provider.

---

## Workstream B — Public-readiness cleanup

- **Hardcoded LAN IP:** replace the three `ws://192.168.1.16:8765/voice`
  defaults in `HermesSessionViewModel` with an empty preset set (no default
  preset) or a neutral `ws://YOUR-MAC-IP:8765/voice` placeholder, so the repo
  ships no personal network address.
- **README rewrite** around two paths:
  1. *Direct (your API) — zero infrastructure.* Install app → Settings → pick
     provider (Claude/OpenAI/Gemini/Local) → paste key → talk. Front-door story.
  2. *Hermes agent (bridge) — full agentic assistant with tools.* Link
     https://hermes-agent.nousresearch.com/docs/getting-started/installation
     (installer: `curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash`,
     or the desktop installer; CLI is `hermes`). Then run the bridge.
  Include a short comparison table (infra needed, tools/agentic, speed, vision).
- **`MetaAppID` docs:** explain that the DAT glasses SDK needs a Meta developer
  App ID; document where to obtain it and that `Info.plist`'s `MetaAppID` /
  `AppLinkURLScheme` must be set. Keep the committed value as a `"0"` placeholder.
- **Untrack scratch:** add `docs/superpowers/plans/` to `.gitignore` and
  `git rm --cached` it (contains personal absolute paths + device UDIDs). Keep
  `docs/superpowers/specs/` (verified free of personal info — useful design docs).
- **`bridge/.env.example`** documenting `HERMES_BRIDGE_TOKEN`, `HERMES_BIN`,
  `HERMES_BRIDGE_BRAIN`, `HERMES_BRIDGE_BASE_URL`, `HERMES_BRIDGE_MODEL`,
  `HERMES_BRIDGE_TTS`, `ANTHROPIC_API_KEY` / provider keys.
- **`CONTRIBUTING.md`** (build/test commands, project layout, PR conventions) and
  a real **Screenshots** section in the README.

---

## Risks / notes

- Each provider's request/response shape differs; the pure `buildRequest`/
  `parseReply` functions plus per-provider tests contain that complexity.
- Vision support varies: Anthropic/OpenAI/Gemini support it; a local Ollama
  model may not. `supportsVision` gates whether a photo is attached; when a
  provider or model lacks vision, the query goes text-only.
- Keychain migration: the account scheme `"<provider-id>_api_key"` yields
  `anthropic_api_key` for the Anthropic provider — byte-for-byte the account
  existing users already have — so saved keys carry over with no migration step.
- Bridge multi-provider is included for symmetry but is the lower-risk half; if
  time-constrained it can land after the app side without blocking the release.
```
