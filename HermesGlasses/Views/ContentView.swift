//
// ContentView.swift
//
// Main view for Hermes Glasses. Shows device connection status,
// Hermes conversation, and controls for starting/stopping sessions.
//

import SwiftUI

struct ContentView: View {
    let wearablesVM: WearablesViewModel
    let hermesVM: HermesSessionViewModel

    @State private var showSettings: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Connection status banner
                connectionBanner

                // Main conversation area
                conversationArea

                // Testing panel — every subsystem as a button
                testPanel

                // Control bar
                controlBar
            }
            .navigationTitle("Hermes Glasses")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(hermesVM: hermesVM, wearablesVM: wearablesVM)
            }
            .task {
                await hermesVM.checkBridge()
            }
        }
    }

    // MARK: - Connection Banner

    @ViewBuilder
    private var connectionBanner: some View {
        HStack(spacing: 12) {
            // Status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(statusSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Mic source indicator
            if hermesVM.connectionState != .disconnected {
                let audio = hermesVM.audio
                Label(
                    audio.isUsingBluetoothInput ? "Glasses Mic" : "iPhone Mic",
                    systemImage: audio.isUsingBluetoothInput ? "eyeglasses" : "iphone.gen3"
                )
                .font(.caption2)
                .foregroundStyle(audio.isUsingBluetoothInput ? .green : .orange)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    (audio.isUsingBluetoothInput ? Color.green : Color.orange)
                        .opacity(0.15),
                    in: Capsule()
                )
            }

            // Glasses connection state
            if wearablesVM.registrationState == .registered {
                Label("Connected", systemImage: "eyeglasses")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.green.opacity(0.15), in: Capsule())
            }

            // Bridge reachability — checked on launch, tap to re-check
            Button {
                Task { await hermesVM.checkBridge() }
            } label: {
                Label(bridgeLabel, systemImage: "server.rack")
                    .font(.caption)
                    .foregroundStyle(bridgeColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(bridgeColor.opacity(0.15), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    private var bridgeLabel: String {
        switch hermesVM.bridgeStatus {
        case .unknown: return "Bridge ?"
        case .checking: return "Bridge …"
        case .reachable: return "Bridge ✓"
        case .unreachable: return "Bridge ✗"
        }
    }

    private var bridgeColor: Color {
        switch hermesVM.bridgeStatus {
        case .reachable: return .green
        case .unreachable: return .red
        case .unknown, .checking: return .gray
        }
    }

    // MARK: - Conversation Area

    @ViewBuilder
    private var conversationArea: some View {
        if hermesVM.conversationHistory.isEmpty && hermesVM.connectionState == .disconnected {
            // Empty state
            VStack(spacing: 16) {
                Image(systemName: "eyeglasses")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)

                Text("Ready to talk to Hermes")
                    .font(.title3)
                    .fontWeight(.medium)

                Text("Connect your Meta Ray-Ban glasses\nand start a voice conversation.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if wearablesVM.registrationState != .registered {
                    Button("Connect Glasses") {
                        wearablesVM.connectGlasses()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxHeight: .infinity)
        } else {
            // Conversation history
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(hermesVM.conversationHistory) { turn in
                            TurnBubble(turn: turn)
                        }

                        // Submitted query awaiting Hermes's answer
                        if !hermesVM.lastTranscript.isEmpty,
                           hermesVM.connectionState == .processing {
                            HStack {
                                Spacer()
                                Text(hermesVM.lastTranscript)
                                    .padding(12)
                                    .background(.blue.opacity(0.15))
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .frame(maxWidth: 280, alignment: .trailing)
                            }
                        }

                        // LIVE transcription — words appear as you speak
                        if !hermesVM.liveTranscript.isEmpty {
                            HStack(alignment: .bottom) {
                                Spacer()
                                Text(hermesVM.liveTranscript)
                                    .italic()
                                    .foregroundStyle(.secondary)
                                    .padding(12)
                                    .background(.blue.opacity(0.08))
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .frame(maxWidth: 280, alignment: .trailing)

                                Button {
                                    hermesVM.sendNow()
                                } label: {
                                    Image(systemName: "arrow.up.circle.fill")
                                        .font(.title2)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        // Live status indicator
                        if case .listening = hermesVM.connectionState {
                            listeningIndicator
                        } else if case .processing = hermesVM.connectionState {
                            processingIndicator
                        } else if case .speaking = hermesVM.connectionState {
                            speakingIndicator
                        }

                        // Scroll anchor
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .padding()
                }
                .onChange(of: hermesVM.conversationHistory.count) { _, _ in
                    withAnimation {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Turn Bubble

    struct TurnBubble: View {
        let turn: ConversationTurn

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                // Photo the glasses captured for this turn
                if let photoData = turn.photo, let image = UIImage(data: photoData) {
                    HStack {
                        Spacer()
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: 200, maxHeight: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }

                // User message
                HStack {
                    Spacer()
                    Text(turn.userText)
                        .padding(12)
                        .background(.blue.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .frame(maxWidth: 280, alignment: .trailing)
                }

                // Agent response
                HStack {
                    Text(turn.agentText)
                        .padding(12)
                        .background(.secondary.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .frame(maxWidth: 280, alignment: .leading)

                    Spacer()
                }
            }
        }
    }

    // MARK: - Indicators

    private var listeningIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.8)

            Text("Listening...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    private var processingIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()

            Text("Thinking...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    private var speakingIndicator: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .symbolEffect(.variableColor.iterative)

            Text("Hermes is speaking...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    // MARK: - Test Panel

    @ViewBuilder
    private var testPanel: some View {
        VStack(spacing: 8) {
            HStack {
                Text("TESTING")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
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

            HStack(spacing: 8) {
                testButton("Bridge") { await hermesVM.testBridge() }
                testButton("Photo") { await hermesVM.testPhoto() }
                testButton("Query") { await hermesVM.testQuery() }
                testButton("Visual") { await hermesVM.testVisualQuery() }
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
        .padding(.horizontal)
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
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .disabled(hermesVM.testRunning.contains(name))
    }

    // MARK: - Control Bar

    @ViewBuilder
    private var controlBar: some View {
        VStack(spacing: 12) {
            // Hermes endpoint info
            if hermesVM.connectionState != .disconnected {
                HStack {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.caption)
                    Text(hermesVM.hermesEndpoint)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            // Main action button
            Button {
                Task {
                    if hermesVM.connectionState == .disconnected {
                        await hermesVM.startSession()
                    } else {
                        hermesVM.endSession()
                    }
                }
            } label: {
                Label(
                    hermesVM.connectionState == .disconnected
                        ? "Start Hermes Session"
                        : "End Session",
                    systemImage: hermesVM.connectionState == .disconnected
                        ? "mic.fill"
                        : "stop.fill"
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(hermesVM.connectionState == .disconnected ? .blue : .red)
            .disabled(
                wearablesVM.registrationState != .registered
                && hermesVM.connectionState == .disconnected
            )
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    // MARK: - Helpers

    private var statusColor: Color {
        switch hermesVM.connectionState {
        case .disconnected: return .gray
        case .connecting: return .orange
        case .listening: return .green
        case .recording: return .red
        case .processing: return .yellow
        case .speaking: return .blue
        case .error: return .red
        }
    }

    private var statusTitle: String {
        switch hermesVM.connectionState {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .listening: return "Listening"
        case .recording: return "Recording"
        case .processing: return "Processing"
        case .speaking: return "Hermes Speaking"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    private var statusSubtitle: String {
        switch wearablesVM.registrationState {
        case .notRegistered: return "Glasses not connected"
        case .registering: return "Pairing with glasses..."
        case .registered: return "Glasses connected"
        case .unavailable: return "Registration unavailable"
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    let hermesVM: HermesSessionViewModel
    let wearablesVM: WearablesViewModel
    @State private var endpoint: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Hermes Agent Endpoint") {
                    TextField("WebSocket URL", text: $endpoint)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)

                    Text("Default: ws://localhost:8765/voice")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Glasses Diagnostics") {
                    LabeledContent("Registration", value: registrationText)
                    LabeledContent(
                        "Devices seen by SDK",
                        value: "\(wearablesVM.devices.count)"
                    )
                    Text("0 devices with \"Registered\" means the glasses aren't reachable over Bluetooth right now, or the pairing is stale.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Button("Re-pair Glasses", role: .destructive) {
                        Task { await wearablesVM.repairGlasses() }
                    }
                }

                Section("About") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Hermes Glasses")
                            .font(.headline)
                        Text("Talk to Hermes AI from your Meta Ray-Ban glasses.")
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
        }
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
