//
// SettingsView.swift
//
// Settings as a hub of sub-pages rather than one long scroll (see
// docs/superpowers/specs/2026-07-20-settings-redesign-design.md). The hub
// shows a glasses status card and one row per area, each carrying the
// value a tester most wants to see at a glance; the detail lives one tap
// deeper.
//
// Text the user types (bridge endpoint, API key) is owned HERE and passed
// down by binding, so the existing "swipe-dismiss must not discard typed
// values" contract still holds no matter which sub-page is open.
//

import SwiftUI

struct SettingsView: View {
    let hermesVM: HermesSessionViewModel
    let wearablesVM: WearablesViewModel

    @State private var endpoint: String = ""
    @State private var providerKey: String = ""
    @AppStorage("show_test_panel") private var showTestPanel: Bool = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        GlassesStatusPage(hermesVM: hermesVM, wearablesVM: wearablesVM)
                    } label: {
                        GlassesStatusCard(hermesVM: hermesVM, wearablesVM: wearablesVM)
                    }
                }

                Section {
                    NavigationLink {
                        AssistantPage(
                            hermesVM: hermesVM,
                            endpoint: $endpoint,
                            providerKey: $providerKey
                        )
                    } label: {
                        row("Assistant", "brain", value: assistantValue)
                    }
                    NavigationLink {
                        VoicePage(hermesVM: hermesVM)
                    } label: {
                        row("Voice & Microphone", "mic", value: hermesVM.micSource.shortLabel)
                    }
                    NavigationLink {
                        DisplayPage(hermesVM: hermesVM)
                    } label: {
                        row("Glasses Display", "eyeglasses",
                            value: hermesVM.displayHUDEnabled ? "On" : "Off")
                    }
                }

                Section {
                    NavigationLink {
                        PeoplePage(hermesVM: hermesVM)
                    } label: {
                        row("People", "person.crop.rectangle.stack",
                            value: hermesVM.socialNotesEnabled ? "On" : "Off")
                    }
                    NavigationLink {
                        NavigationPage(hermesVM: hermesVM)
                    } label: {
                        row("Navigation & Maps", "map",
                            value: hermesVM.navigationEnabled ? "On" : "Off")
                    }
                    NavigationLink {
                        ContextPage(hermesVM: hermesVM)
                    } label: {
                        row("Context & Privacy", "location",
                            value: hermesVM.contextEnabled ? "Sharing" : "Off")
                    }
                }

                // Testers land here first: everything you can say, in one
                // place, generated from the detectors themselves.
                Section {
                    NavigationLink {
                        VoiceCommandsPage()
                    } label: {
                        row("What can I say?", "text.bubble", value: nil)
                    }
                }

                Section {
                    NavigationLink {
                        DeveloperPage(showTestPanel: $showTestPanel)
                    } label: {
                        row("Developer", "hammer",
                            value: showTestPanel ? "Test panel on" : nil)
                    }
                }

                Section {
                    VStack(spacing: 4) {
                        Text("Hermes Glasses 1.0")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Talk to your AI from your Meta Ray-Ban glasses.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        commitTypedValues()
                        dismiss()
                    }
                }
            }
            .onAppear { endpoint = hermesVM.hermesEndpoint }
            .onDisappear(perform: commitTypedValues)
        }
        .tint(HermesTheme.accent)
    }

    private var assistantValue: String {
        hermesVM.backend == .direct ? hermesVM.directProvider.displayName : "Bridge"
    }

    private func row(_ title: String, _ icon: String, value: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(HermesTheme.accent)
                .frame(width: 24)
            Text(title)
            Spacer(minLength: 8)
            if let value {
                Text(value)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    /// Swipe-dismiss must not silently discard typed values.
    private func commitTypedValues() {
        hermesVM.setEndpoint(endpoint)
        if !providerKey.trimmingCharacters(in: .whitespaces).isEmpty {
            hermesVM.setProviderKey(providerKey)
            providerKey = ""
        }
    }
}

// MARK: - Status card

private struct GlassesStatusCard: View {
    let hermesVM: HermesSessionViewModel
    let wearablesVM: WearablesViewModel

    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                Circle()
                    .fill(HermesTheme.accent.opacity(0.14))
                    .frame(width: 42, height: 42)
                Image(systemName: "eyeglasses")
                    .font(.system(size: 19))
                    .foregroundStyle(HermesTheme.accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Ray-Ban Display")
                    .font(.system(size: 16, weight: .semibold))
                HStack(spacing: 6) {
                    Circle()
                        .fill(hermesVM.isGlassesConnected ? .green : .secondary)
                        .frame(width: 7, height: 7)
                    Text(statusLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var statusLine: String {
        let connection = hermesVM.isGlassesConnected ? "Connected" : "Not connected"
        let count = wearablesVM.devices.count
        return "\(connection) · \(registrationText) · \(count) device\(count == 1 ? "" : "s")"
    }

    private var registrationText: String {
        switch wearablesVM.registrationState {
        case .notRegistered: return "Not registered"
        case .registering: return "Registering…"
        case .registered: return "Registered"
        case .unavailable: return "Unavailable"
        }
    }
}

// MARK: - Glasses

private struct GlassesStatusPage: View {
    let hermesVM: HermesSessionViewModel
    let wearablesVM: WearablesViewModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Registration", value: registrationText)
                LabeledContent("Devices seen by SDK", value: "\(wearablesVM.devices.count)")
                LabeledContent("Camera permission", value: cameraPermissionText)
                LabeledContent("Display", value: displayStatusText)
            } header: {
                Text("Status")
            } footer: {
                Text("0 devices with \"Registered\" means the glasses aren't reachable over Bluetooth right now, or the pairing is stale. Camera permission is granted on first photo, via the Meta AI app.")
            }

            Section {
                Button("Re-pair Glasses", role: .destructive) {
                    Task { await wearablesVM.repairGlasses() }
                }
            }
        }
        .navigationTitle("Glasses")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var registrationText: String {
        switch wearablesVM.registrationState {
        case .notRegistered: return "Not registered"
        case .registering: return "Registering…"
        case .registered: return "Registered"
        case .unavailable: return "Unavailable"
        }
    }

    private var cameraPermissionText: String {
        switch hermesVM.cameraPermissionGranted {
        case .some(true): return "Granted"
        case .some(false): return "Denied - tap Photo test to grant"
        case .none: return "Unknown (start a session)"
        }
    }

    private var displayStatusText: String {
        switch hermesVM.displayStatus {
        case .off: return hermesVM.displayHUDEnabled ? "Off (no session)" : "Disabled"
        case .connecting: return "Connecting…"
        case .connected:
            // Glasses HFP mic = their own call screen covers the HUD
            return hermesVM.lensBlockedByCallScreen
                ? "Connected - hidden by call screen (glasses mic)"
                : "Connected"
        case .unavailable(let reason): return "Unavailable - \(reason)"
        }
    }
}

// MARK: - Assistant

private struct AssistantPage: View {
    let hermesVM: HermesSessionViewModel
    @Binding var endpoint: String
    @Binding var providerKey: String

    @State private var showSavePreset: Bool = false
    @State private var presetName: String = ""
    @State private var presetsVersion: Int = 0  // bump to refresh list

    var body: some View {
        Form {
            Section {
                Picker("Backend", selection: Binding(
                    get: { hermesVM.backend }, set: { hermesVM.backend = $0 })) {
                    ForEach(AssistantBackend.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if hermesVM.backend == .direct {
                    Picker("Provider", selection: Binding(
                        get: { hermesVM.directProviderID },
                        set: { hermesVM.directProviderID = $0 })) {
                        ForEach(AIProviderRegistry.all, id: \.id) { p in
                            Text(p.displayName).tag(p.id)
                        }
                    }
                    if hermesVM.directProvider.allowsCustomBaseURL {
                        TextField("Base URL", text: Binding(
                            get: { hermesVM.directBaseURL },
                            set: { hermesVM.directBaseURL = $0 }))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                    }
                    Picker("Model", selection: Binding(
                        get: { hermesVM.directModel },
                        set: { hermesVM.directModel = $0 })) {
                        ForEach(hermesVM.directProvider.curatedModels, id: \.id) { m in
                            Text(m.label).tag(m.id)
                        }
                        // Allow a stored custom model to remain selectable
                        if !hermesVM.directProvider.curatedModels.contains(where: { $0.id == hermesVM.directModel }) {
                            Text(hermesVM.directModel).tag(hermesVM.directModel)
                        }
                    }
                    if hermesVM.directProvider.requiresKey {
                        SecureField("\(hermesVM.directProvider.displayName) API key",
                                    text: $providerKey)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .onSubmit {
                                hermesVM.setProviderKey(providerKey)
                                providerKey = ""
                            }
                        LabeledContent("Key status",
                            value: hermesVM.hasDirectKey ? "Saved in Keychain" : "Not set")
                    }
                }
            } footer: {
                if hermesVM.backend == .direct {
                    Text("Direct mode needs no server - the phone calls \(hermesVM.directProvider.displayName) with your key. Applies from the next session.")
                }
            }

            // Only relevant when the bridge is actually in play.
            if hermesVM.backend == .bridge {
                Section {
                    ForEach(hermesVM.endpointPresets, id: \.name) { preset in
                        Button {
                            endpoint = preset.url
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.name)
                                        .foregroundStyle(.primary)
                                    Text(preset.url)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if endpoint == preset.url {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(HermesTheme.accent)
                                }
                            }
                        }
                        .swipeActions {
                            Button("Delete", role: .destructive) {
                                hermesVM.deletePreset(name: preset.name)
                                presetsVersion += 1
                            }
                        }
                    }
                    .id(presetsVersion)

                    TextField("WebSocket URL", text: $endpoint)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(size: 15, design: .monospaced))

                    Button("Save current URL as preset…") {
                        presetName = ""
                        showSavePreset = true
                    }
                    .disabled(endpoint.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("Bridge connection")
                } footer: {
                    Text("Bridge endpoint used in Bridge mode. Tap a preset to select it.")
                }
            }
        }
        .navigationTitle("Assistant")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Save preset", isPresented: $showSavePreset) {
            TextField("Name (e.g. Maya remote)", text: $presetName)
            Button("Save") {
                hermesVM.savePreset(name: presetName, url: endpoint)
                presetsVersion += 1
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the current URL so you can switch with one tap.")
        }
    }
}

// MARK: - Voice & Microphone

private struct VoicePage: View {
    let hermesVM: HermesSessionViewModel

    var body: some View {
        Form {
            Section {
                Picker("Voice input", selection: Binding(
                    get: { hermesVM.micSource },
                    set: { newValue in
                        if newValue != hermesVM.micSource {
                            Task { await hermesVM.setMicSource(newValue) }
                        }
                    }
                )) {
                    ForEach(MicSource.allCases, id: \.self) { source in
                        Text(source.label).tag(source)
                    }
                }
                .pickerStyle(.inline)
            } header: {
                Text("Microphone")
            } footer: {
                Text("Glasses mode shows a CALL SCREEN on the lens and hides the HUD. Headset mode (AirPods etc.) is the pocket setup: talk and listen through the earbuds while the lens keeps the HUD. Audio never leaves your phone for speech-to-text.")
            }

            Section {
                Toggle("iPhone voice", isOn: Binding(
                    get: { hermesVM.useDeviceTTS },
                    set: { hermesVM.useDeviceTTS = $0 }
                ))
            } header: {
                Text("Voice")
            } footer: {
                Text("On = faster but more robotic, generated on the phone. Off = natural voice generated on the bridge (adds 1–3 s per reply). Applies from the next question.")
            }
        }
        .navigationTitle("Voice & Microphone")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Glasses Display

private struct DisplayPage: View {
    let hermesVM: HermesSessionViewModel

    var body: some View {
        Form {
            Section {
                Toggle("Show HUD on glasses", isOn: Binding(
                    get: { hermesVM.displayHUDEnabled },
                    set: { hermesVM.displayHUDEnabled = $0 }
                ))
                Toggle("Silent mode", isOn: Binding(
                    get: { hermesVM.displaySilentMode },
                    set: { hermesVM.displaySilentMode = $0 }
                ))
                .disabled(!hermesVM.displayHUDEnabled)
            } footer: {
                Text("Ray-Ban Display glasses only: live transcript, replies, and controls on the lens. Silent mode shows the reply as text instead of speaking it - handy in meetings. Note: the glasses microphone's call screen covers the HUD; the iPhone or a headset mic keeps it visible.")
            }
        }
        .navigationTitle("Glasses Display")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - People

private struct PeoplePage: View {
    let hermesVM: HermesSessionViewModel

    var body: some View {
        Form {
            Section {
                Toggle("Remember people I meet", isOn: Binding(
                    get: { hermesVM.socialNotesEnabled },
                    set: { hermesVM.socialNotesEnabled = $0 }
                ))
            } footer: {
                Text("Say \"remember this person\" at a gathering: the glasses take a photo and the note you speak next is saved with it. Say \"cancel\" instead of a note to throw the capture away. Stays on your phone - no AI, no server.")
            }

            Section {
                LabeledContent("Saved", value: "\(hermesVM.allEncounters().count)")
            } footer: {
                Text("Review, edit, and delete them on the People screen - the person icon in the main header.")
            }

            Section {
                ForEach(VoiceCommandCatalog.groups.filter { $0.id.hasPrefix("people") }) { group in
                    NavigationLink {
                        VoiceCommandsPage(highlighted: group.id)
                    } label: {
                        Text(group.title)
                    }
                }
            } header: {
                Text("What to say")
            }
        }
        .navigationTitle("People")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Navigation & Maps

private struct NavigationPage: View {
    let hermesVM: HermesSessionViewModel
    @State private var mapboxTokenInput: String = ""

    var body: some View {
        Form {
            Section {
                Toggle("Navigate on \"take me to…\"", isOn: Binding(
                    get: { hermesVM.navigationEnabled },
                    set: { hermesVM.navigationEnabled = $0 }
                ))
                Toggle("Show a picture on \"what is…\"", isOn: Binding(
                    get: { hermesVM.definitionImagesEnabled },
                    set: { hermesVM.definitionImagesEnabled = $0 }
                ))
            }

            Section {
                SecureField("Mapbox access token", text: $mapboxTokenInput)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button(hermesVM.hasMapboxToken ? "Update token" : "Save token") {
                    MapCredentials.storeToken(mapboxTokenInput)
                    hermesVM.hasMapboxToken = MapCredentials.hasToken
                    mapboxTokenInput = ""
                }
                .disabled(mapboxTokenInput.trimmingCharacters(in: .whitespaces).isEmpty)
                LabeledContent("Token",
                    value: hermesVM.hasMapboxToken ? "Saved in Keychain" : "Not set")
            } header: {
                Text("Mapbox")
            } footer: {
                if !hermesVM.hasMapboxToken {
                    Text("Navigation shows text directions until a Mapbox token is added. Get a free token at mapbox.com.")
                }
            }
        }
        .navigationTitle("Navigation & Maps")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Context & Privacy

private struct ContextPage: View {
    let hermesVM: HermesSessionViewModel

    var body: some View {
        Form {
            Section {
                Toggle("Share my context", isOn: Binding(
                    get: { hermesVM.contextEnabled },
                    set: { hermesVM.contextEnabled = $0 }
                ))
                Toggle("Include precise coordinates", isOn: Binding(
                    get: { hermesVM.contextPreciseLocation },
                    set: { hermesVM.contextPreciseLocation = $0 }
                ))
                .disabled(!hermesVM.contextEnabled)
            } footer: {
                Text("Attached to every question so the assistant knows your time, place, and status. Weather is fetched from open-meteo.com using your coordinates.")
            }

            if hermesVM.contextEnabled {
                Section {
                    Text(hermesVM.contextPreview ?? "Gathering…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("What gets sent")
                } footer: {
                    Text("The line above is exactly what gets sent.")
                }
            }
        }
        .navigationTitle("Context & Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Voice commands (tester reference)

struct VoiceCommandsPage: View {
    /// Scrolls to and tints one group - used when arriving from a feature
    /// page that owns that command.
    var highlighted: String? = nil

    var body: some View {
        List {
            Section {
                Text("Say these while a session is running. Hermes acts on them on the phone, before the AI sees anything - so they work the same in Direct and Bridge mode.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            ForEach(VoiceCommandCatalog.groups) { group in
                Section {
                    ForEach(group.examples, id: \.self) { example in
                        Text("\"\(example)\"")
                            .font(.system(size: 15, design: .rounded))
                            .textSelection(.enabled)
                    }

                    if let followUp = group.followUp {
                        Text(followUp)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    DisclosureGroup("All \(group.phrases.count) phrases") {
                        Text(group.phrases.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    if let setting = group.setting {
                        LabeledContent("Setting", value: setting)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    HStack {
                        Text(group.title)
                        if group.id == highlighted {
                            Image(systemName: "arrow.left")
                                .foregroundStyle(HermesTheme.accent)
                        }
                    }
                } footer: {
                    Text(group.summary)
                }
            }
        }
        .navigationTitle("What can I say?")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Developer

private struct DeveloperPage: View {
    @Binding var showTestPanel: Bool

    var body: some View {
        Form {
            Section {
                Toggle("Test panel", isOn: $showTestPanel)
            } footer: {
                Text("Shows the subsystem test buttons and mic meter on the main screen.")
            }
        }
        .navigationTitle("Developer")
        .navigationBarTitleDisplayMode(.inline)
    }
}
