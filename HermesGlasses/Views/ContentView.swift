//
// ContentView.swift
//
// Main view for Hermes Glasses. Chat-first session screen per the
// "Hermes Glasses UI" design: header with status chips, message
// bubbles, live transcription bubble, waveform bottom bar.
//

import SwiftUI

// MARK: - Theme

enum HermesTheme {
    /// Terracotta accent from the design (#C4622D)
    static let accent = Color(red: 196 / 255, green: 98 / 255, blue: 45 / 255)

    /// Neutral chip/bubble fill that adapts to light/dark
    static let chipFill = Color(uiColor: .tertiarySystemFill)

    /// Assistant bubble fill (≈ #E9E9EB light / #26262A dark)
    static let assistantBubble = Color(uiColor: .systemGray5)
}

struct ContentView: View {
    let wearablesVM: WearablesViewModel
    let hermesVM: HermesSessionViewModel

    @State private var showSettings: Bool = false
    @AppStorage("show_test_panel") private var showTestPanel: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            header
            conversationArea
            if showTestPanel {
                testPanel
            }
            bottomBar
        }
        .background(Color(.systemBackground))
        .tint(HermesTheme.accent)
        .sheet(isPresented: $showSettings) {
            SettingsView(hermesVM: hermesVM, wearablesVM: wearablesVM)
        }
        .task {
            await hermesVM.checkBridge()
        }
    }

    // MARK: - Header (title + status chips)

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 6) {
            Text(assistantName)
                .font(.system(size: 20, weight: .bold))
                .kerning(-0.4)

            Spacer(minLength: 4)

            // Glasses connection
            statusChip("Glasses", dot: glassesDotColor)

            // Bridge reachability (or Claude key status in direct mode)
            if hermesVM.backend == .direct {
                statusChip(hermesVM.directProvider.displayName,
                           dot: (!hermesVM.directProvider.requiresKey || hermesVM.hasDirectKey) ? .green : .red)
            } else {
                Button {
                    Task { await hermesVM.checkBridge() }
                } label: {
                    statusChip("Bridge", dot: bridgeDotColor)
                }
                .buttonStyle(.plain)
            }

            // Mic source — tap cycles iPhone → Glasses → Headset
            if hermesVM.connectionState != .disconnected {
                iconCircle(
                    micIconName,
                    tint: hermesVM.audio.isUsingBluetoothInput
                        ? HermesTheme.accent : .secondary
                ) {
                    Task { await hermesVM.toggleMicSource() }
                }
            }

            // New conversation
            iconCircle("square.and.pencil", tint: .secondary) {
                hermesVM.startNewConversation()
            }
            .disabled(hermesVM.connectionState == .disconnected)
            .opacity(hermesVM.connectionState == .disconnected ? 0.4 : 1)

            // Settings
            iconCircle("gearshape", tint: .secondary) {
                showSettings = true
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private func statusChip(_ label: String, dot: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(dot)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(HermesTheme.chipFill, in: Capsule())
    }

    private func iconCircle(
        _ systemName: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(HermesTheme.chipFill, in: Circle())
        }
        .buttonStyle(.plain)
    }

    private var micIconName: String {
        switch hermesVM.micSource {
        case .phone: return "iphone.gen3"
        case .glasses: return "eyeglasses"
        case .headset: return "headphones"
        }
    }

    private var glassesDotColor: Color {
        wearablesVM.registrationState == .registered ? .green : .red
    }

    private var bridgeDotColor: Color {
        switch hermesVM.bridgeStatus {
        case .reachable: return .green
        case .unreachable: return .red
        case .unknown, .checking: return .gray
        }
    }

    // MARK: - Conversation Area

    @ViewBuilder
    private var conversationArea: some View {
        if hermesVM.conversationHistory.isEmpty
            && hermesVM.connectionState == .disconnected {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(hermesVM.conversationHistory) { turn in
                            TurnBubble(turn: turn)
                        }

                        // Submitted query awaiting the answer
                        if !hermesVM.lastTranscript.isEmpty,
                           hermesVM.connectionState == .processing {
                            UserBubble(text: hermesVM.lastTranscript)
                        }

                        // LIVE transcription — words appear as you speak
                        if !hermesVM.liveTranscript.isEmpty {
                            liveTranscriptBubble
                        }

                        // Live status indicator
                        if case .processing = hermesVM.connectionState {
                            processingIndicator
                        } else if case .speaking = hermesVM.connectionState {
                            speakingIndicator
                        }

                        // Scroll anchor
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .onChange(of: hermesVM.conversationHistory.count) { _, _ in
                    withAnimation {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onChange(of: hermesVM.liveTranscript) { _, _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private var liveTranscriptBubble: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Spacer(minLength: 60)

            VStack(alignment: .trailing, spacing: 4) {
                Text(hermesVM.liveTranscript)
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(HermesTheme.chipFill, in: userBubbleShape)
                    .overlay(
                        userBubbleShape
                            .strokeBorder(
                                Color.secondary.opacity(0.35),
                                style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                            )
                    )

                Text("Transcribing on device…")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }

            Button {
                hermesVM.sendNow()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(HermesTheme.accent)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 20)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            Spacer()

            RoundedRectangle(cornerRadius: 20)
                .fill(HermesTheme.chipFill)
                .frame(width: 220, height: 130)
                .overlay {
                    Image(systemName: "eyeglasses")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                }

            VStack(spacing: 8) {
                Text(wearablesVM.registrationState == .registered
                    ? "Ready to talk to \(assistantName)"
                    : "Connect your glasses")
                    .font(.system(size: 28, weight: .bold))
                    .kerning(-0.5)

                Text("\(assistantName) talks to you through your Meta Ray-Ban glasses — mic, speaker, and camera.")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }

            if wearablesVM.registrationState != .registered {
                Button {
                    wearablesVM.connectGlasses()
                } label: {
                    Text("Connect Glasses")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(HermesTheme.accent, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)

                Text("You'll finish registration in the Meta AI app")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Bubbles

    private var userBubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 20, bottomLeadingRadius: 20,
            bottomTrailingRadius: 6, topTrailingRadius: 20
        )
    }

    struct UserBubble: View {
        let text: String

        var body: some View {
            HStack {
                Spacer(minLength: 60)
                Text(text)
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        HermesTheme.accent,
                        in: UnevenRoundedRectangle(
                            topLeadingRadius: 20, bottomLeadingRadius: 20,
                            bottomTrailingRadius: 6, topTrailingRadius: 20
                        )
                    )
            }
        }
    }

    struct AssistantBubble: View {
        let text: String

        var body: some View {
            HStack {
                Text(text)
                    .font(.system(size: 16))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        HermesTheme.assistantBubble,
                        in: UnevenRoundedRectangle(
                            topLeadingRadius: 20, bottomLeadingRadius: 6,
                            bottomTrailingRadius: 20, topTrailingRadius: 20
                        )
                    )
                Spacer(minLength: 48)
            }
        }
    }

    struct TurnBubble: View {
        let turn: ConversationTurn

        var body: some View {
            VStack(alignment: .leading, spacing: 10) {
                // Photo the glasses captured for this turn
                if let photoData = turn.photo,
                   let image = UIImage(data: photoData) {
                    HStack {
                        Spacer()
                        PhotoCard(image: image)
                    }
                }

                UserBubble(text: turn.userText)
                AssistantBubble(text: turn.agentText)
            }
        }
    }

    /// Captured glasses photo with a "Ray-Ban camera" caption bar
    struct PhotoCard: View {
        let image: UIImage

        var body: some View {
            VStack(spacing: 0) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 200, height: 130)
                    .clipped()

                HStack(spacing: 5) {
                    Image(systemName: "camera")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Ray-Ban camera")
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(.secondarySystemGroupedBackground))
            }
            .frame(width: 200)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.1), radius: 3, y: 1)
        }
    }

    // MARK: - Indicators

    private var processingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.8)
            Text("Thinking…")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }

    private var speakingIndicator: some View {
        Button {
            hermesVM.interruptSpeech()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 11))
                    .symbolEffect(.variableColor.iterative)
                Text(speakingLabel)
                    .font(.system(size: 11, weight: .semibold))
                Image(systemName: "stop.circle")
                    .font(.system(size: 12))
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }

    private var speakingLabel: String {
        if hermesVM.audio.isUsingBluetoothInput {
            let device = hermesVM.micSource == .headset ? "headset" : "glasses"
            return "\(assistantName) speaking through \(device) — tap to stop"
        }
        return "\(assistantName) is speaking — tap to stop"
    }

    // MARK: - Test Panel

    @ViewBuilder
    private var testPanel: some View {
        VStack(spacing: 8) {
            HStack {
                Text("TESTING")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Spacer()
                // Live mic level meter
                HStack(spacing: 4) {
                    Image(systemName: "mic.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ProgressView(value: min(1.0, Double(hermesVM.micLevel) * 8))
                        .frame(width: 80)
                }
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                spacing: 8
            ) {
                testButton("Bridge") { await hermesVM.testBridge() }
                testButton("Sound") { await hermesVM.testSound() }
                testButton("Photo") { await hermesVM.testPhoto() }
                testButton("Query") { await hermesVM.testQuery() }
                testButton("Visual") { await hermesVM.testVisualQuery() }
                testButton("Display") { await hermesVM.testDisplay() }
            }

            // Most recent failure message, if any
            if let failure = hermesVM.testResults.values
                .compactMap({ $0 }).first(where: { !$0.isEmpty }) {
                Text(failure)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private func testButton(
        _ name: String,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            HStack(spacing: 4) {
                if hermesVM.testRunning.contains(name) {
                    ProgressView().scaleEffect(0.6)
                } else if let result = hermesVM.testResults[name] ?? nil {
                    Image(systemName: result.isEmpty
                        ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.isEmpty ? .green : .red)
                }
                Text(name)
                    .font(.caption)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .disabled(hermesVM.testRunning.contains(name))
    }

    // MARK: - Bottom Bar (waveform + End / Start)

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider()

            if hermesVM.connectionState == .disconnected {
                // Big accent start button
                Button {
                    Task { await hermesVM.startSession() }
                } label: {
                    Text("Start Session")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(
                            wearablesVM.registrationState == .registered
                                ? HermesTheme.accent
                                : Color(.systemGray3),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .disabled(wearablesVM.registrationState != .registered)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            } else {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        WaveformView(
                            level: hermesVM.micLevel,
                            accent: HermesTheme.accent
                        )
                        Text(bottomStatusLabel)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(isErrorState ? .red : .secondary)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        hermesVM.endSession()
                    } label: {
                        Text("End")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 18)
                            .frame(height: 40)
                            .background(.red.opacity(0.13), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
        .background(.ultraThinMaterial)
    }

    private var isErrorState: Bool {
        if case .error = hermesVM.connectionState { return true }
        return false
    }

    private var bottomStatusLabel: String {
        switch hermesVM.connectionState {
        case .disconnected: return ""
        case .connecting: return "Connecting…"
        case .listening: return "Listening"
        case .recording: return "Listening"
        case .processing: return "Thinking…"
        case .speaking: return "\(assistantName) speaking"
        case .error(let msg): return msg
        }
    }

    // MARK: - Helpers

    /// Who the user is talking to, per the selected backend
    private var assistantName: String {
        hermesVM.backend == .direct ? hermesVM.directProvider.displayName : "Hermes"
    }
}

// MARK: - Waveform

/// Mic-level waveform: bars with a sine envelope, per the design
struct WaveformView: View {
    let level: Float
    let accent: Color

    private let barCount = 30

    var body: some View {
        HStack(spacing: 3.5) {
            ForEach(0..<barCount, id: \.self) { i in
                let env = sin(Double(i) / Double(barCount - 1) * .pi)
                let wobble = 0.35 + 0.65 * abs(sin(Double(i) * 2.7 + 1.3))
                Capsule()
                    .fill(accent.opacity(0.45 + 0.55 * env))
                    .frame(
                        width: 3,
                        height: max(3, 24 * amplitude * env * wobble)
                    )
            }
        }
        .frame(height: 28, alignment: .center)
        .animation(.linear(duration: 0.12), value: level)
    }

    private var amplitude: Double {
        min(1.0, Double(level) * 10)
    }
}

// MARK: - Settings View

struct SettingsView: View {
    let hermesVM: HermesSessionViewModel
    let wearablesVM: WearablesViewModel
    @State private var endpoint: String = ""
    @State private var claudeKey: String = ""
    @State private var showSavePreset: Bool = false
    @State private var presetName: String = ""
    @State private var presetsVersion: Int = 0  // bump to refresh list
    @AppStorage("show_test_panel") private var showTestPanel: Bool = true
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
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
                            SecureField("\(hermesVM.directProvider.displayName) API key", text: $claudeKey)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .onSubmit {
                                    hermesVM.setProviderKey(claudeKey)
                                    claudeKey = ""
                                }
                            LabeledContent("Key status",
                                value: hermesVM.hasDirectKey ? "Saved in Keychain" : "Not set")
                        }
                    }
                } header: {
                    Text("Assistant")
                } footer: {
                    if hermesVM.backend == .direct {
                        Text("Direct mode needs no server — the phone calls \(hermesVM.directProvider.displayName) with your key. Applies from the next session.")
                    }
                }

                Section {
                    // Saved presets — tap to select
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
                    Text("Connection")
                } footer: {
                    Text("Bridge endpoint used in Bridge mode. Tap a preset to select it.")
                }

                Section {
                    Toggle("iPhone voice (faster, more robotic)", isOn: Binding(
                        get: { hermesVM.useDeviceTTS },
                        set: { hermesVM.useDeviceTTS = $0 }
                    ))
                } header: {
                    Text("Voice")
                } footer: {
                    Text("Off = natural voice generated on the bridge (adds 1–3 s per reply). Applies from the next question.")
                }

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
                } header: {
                    Text("Microphone")
                } footer: {
                    Text("Glasses mode shows a CALL SCREEN on the lens and hides the HUD. Headset mode (AirPods etc.) is the pocket setup: talk and listen through the earbuds while the lens keeps the HUD. Audio never leaves your phone for speech-to-text.")
                }

                Section {
                    Toggle("Show HUD on glasses", isOn: Binding(
                        get: { hermesVM.displayHUDEnabled },
                        set: { hermesVM.displayHUDEnabled = $0 }
                    ))
                    Toggle("Silent mode (read, don't speak)", isOn: Binding(
                        get: { hermesVM.displaySilentMode },
                        set: { hermesVM.displaySilentMode = $0 }
                    ))
                    .disabled(!hermesVM.displayHUDEnabled)
                } header: {
                    Text("Glasses Display")
                } footer: {
                    Text("Ray-Ban Display glasses only: live transcript, replies, and controls on the lens. Silent mode shows the reply as text instead of speaking it — handy in meetings. Note: the glasses microphone's call screen covers the HUD; the iPhone or a headset mic keeps it visible.")
                }

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
                    if hermesVM.contextEnabled {
                        Text(hermesVM.contextPreview ?? "Gathering…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Context")
                } footer: {
                    Text("Attached to every question so the assistant knows your time, place, and status. Weather is fetched from open-meteo.com using your coordinates. The line above is exactly what gets sent.")
                }

                Section {
                    LabeledContent("Registration", value: registrationText)
                    LabeledContent(
                        "Devices seen by SDK",
                        value: "\(wearablesVM.devices.count)"
                    )
                    LabeledContent(
                        "Camera permission",
                        value: cameraPermissionText
                    )
                    LabeledContent("Display", value: displayStatusText)
                    Button("Re-pair Glasses", role: .destructive) {
                        Task { await wearablesVM.repairGlasses() }
                    }
                } header: {
                    Text("Glasses")
                } footer: {
                    Text("0 devices with \"Registered\" means the glasses aren't reachable over Bluetooth right now, or the pairing is stale. Camera permission is granted on first photo, via the Meta AI app.")
                }

                Section {
                    Toggle("Test panel", isOn: $showTestPanel)
                } header: {
                    Text("Developer")
                } footer: {
                    Text("Shows the subsystem test buttons and mic meter on the main screen.")
                }

                Section("About") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Hermes Glasses")
                            .font(.headline)
                        Text("Talk to your AI from your Meta Ray-Ban glasses.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        hermesVM.setEndpoint(endpoint)
                        dismiss()
                    }
                }
            }
            .onAppear {
                endpoint = hermesVM.hermesEndpoint
            }
            .onDisappear {
                // Swipe-dismiss must not silently discard typed values
                hermesVM.setEndpoint(endpoint)
                if !claudeKey.trimmingCharacters(in: .whitespaces).isEmpty {
                    hermesVM.setProviderKey(claudeKey)
                }
            }
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
        .tint(HermesTheme.accent)
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
        case .some(false): return "Denied — tap Photo test to grant"
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
                ? "Connected — hidden by call screen (glasses mic)"
                : "Connected"
        case .unavailable(let reason): return "Unavailable — \(reason)"
        }
    }
}
