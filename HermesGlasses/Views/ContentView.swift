//
// ContentView.swift
//
// Main view for Hermes Glasses. Chat-first session screen per screen 4a
// of the "Hermes Glasses UI" design: brand lockup + status pills in the
// header, terracotta/white bubbles on a cream canvas, a quick-action row
// to the four feature screens, and a waveform bottom bar.
//
// The subsystem test buttons used to float over this screen; per turn 5
// of the design they now live in Settings -> Developer, so nothing
// covers the conversation.
//

import SwiftUI

/// The user-bubble shape (rounded, tail on the bottom-trailing corner) -
/// shared so `ContentView.liveTranscriptBubble` and the nested `UserBubble`
/// draw the exact same geometry instead of each carrying its own copy.
fileprivate let userBubbleShape = UnevenRoundedRectangle(
    topLeadingRadius: 20, bottomLeadingRadius: 20,
    bottomTrailingRadius: 6, topTrailingRadius: 20
)

// MARK: - Appearance

/// Light/dark override for the whole app. `.system` follows the phone.
/// Persisted under `appearance_mode`; read at the app root as a
/// `.preferredColorScheme`. The UI already uses adaptive colours, so
/// both schemes render correctly - this just lets the user force one.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "appearance_mode"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

struct ContentView: View {
    let wearablesVM: WearablesViewModel
    let hermesVM: HermesSessionViewModel
    let buildCheckVM: BuildCheckViewModel
    let machineGuideVM: MachineGuideViewModel

    @State private var showSettings: Bool = false
    @State private var showPeople: Bool = false
    @State private var showLens: Bool = false
    @State private var showObjectLog: Bool = false
    @State private var showMap: Bool = false
    @State private var showLookup: Bool = false
    @State private var showBuildCheck: Bool = false
    @State private var showManuals: Bool = false
    /// In phone mode the 5b camera view is the session screen; this flips to
    /// the chat transcript so the conversation is never unreachable.
    @State private var showTranscript: Bool = false
    /// Set when Settings should open straight onto a sub-page.
    @State private var settingsRoute: SettingsRoute?
    @State private var showAppDrawer: Bool = false
    /// Apps the user has opened at least once / What's-new cards they
    /// closed (comma-separated ids; see HermesAppRegistry.idSet).
    @AppStorage("apps_opened") private var appsOpenedRaw = ""
    @AppStorage("whats_new_dismissed") private var whatsNewDismissedRaw = ""

    private var openedAppIDs: Set<String> { HermesAppRegistry.idSet(from: appsOpenedRaw) }
    private var unseenNewAppIDs: Set<String> {
        Set(HermesAppRegistry.unseenNew(opened: openedAppIDs).map(\.id))
    }
    private var whatsNewApp: HermesApp? {
        HermesAppRegistry.whatsNew(
            opened: openedAppIDs,
            dismissed: HermesAppRegistry.idSet(from: whatsNewDismissedRaw))
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsPhoneModeStage {
                PhoneModeSessionView(
                    hermesVM: hermesVM,
                    onShowTranscript: { showTranscript = true },
                    onOpenDevices: { showSettings = true }
                )
            } else {
                header
                conversationArea
                quickActions
            }
            // A clip started from the glasses button has no screen of its
            // own - without this the wearer can't tell it's recording.
            if hermesVM.clipStarting || hermesVM.clipRecording {
                ClipStatusBanner(hermesVM: hermesVM)
            } else if let app = whatsNewApp {
                WhatsNewCard(
                    app: app,
                    onOpen: { open(app) },
                    onDismiss: {
                        var dismissed = HermesAppRegistry.idSet(from: whatsNewDismissedRaw)
                        dismissed.insert(app.id)
                        whatsNewDismissedRaw = HermesAppRegistry.idString(dismissed)
                    })
            }
            bottomBar
        }
        .background(showsPhoneModeStage
            ? HermesTheme.lensChrome : HermesTheme.canvas)
        .tint(HermesTheme.accent)
        .sheet(isPresented: $showSettings, onDismiss: { settingsRoute = nil }) {
            SettingsView(
                hermesVM: hermesVM, wearablesVM: wearablesVM,
                initialRoute: settingsRoute
            )
        }
        // Pairing errors are actionable: "already registered" means the fix
        // is re-pairing, which lives in Devices.
        .alert("Glasses", isPresented: Binding(
            get: { wearablesVM.showError },
            set: { if !$0 { wearablesVM.dismissError() } }
        )) {
            Button("Open Devices") {
                wearablesVM.dismissError()
                openDevices()
            }
            Button("OK", role: .cancel) { wearablesVM.dismissError() }
        } message: {
            Text(wearablesVM.errorMessage)
        }
        .sheet(isPresented: $showPeople) {
            PeopleView(hermesVM: hermesVM)
        }
        .sheet(isPresented: $showObjectLog) {
            ObjectLogView(hermesVM: hermesVM)
        }
        .sheet(isPresented: $showMap) {
            NavigationMapView(hermesVM: hermesVM)
        }
        .sheet(isPresented: $showAppDrawer) {
            AppDrawerView(
                apps: HermesAppRegistry.all,
                unavailable: unavailableReason,
                onOpen: open,
                isNew: { unseenNewAppIDs.contains($0.id) }
            )
            .presentationDetents([.medium, .large])
        }
        // fullScreenCover, not sheet - an accidental drag-dismiss would
        // tear down the live stream mid-use; Done is the exit.
        .fullScreenCover(isPresented: $showLens) {
            LensView(hermesVM: hermesVM)
        }
        .fullScreenCover(isPresented: $showLookup) {
            LookupView(hermesVM: hermesVM)
        }
        .sheet(isPresented: $showBuildCheck) {
            BuildCheckView(vm: buildCheckVM)
        }
        .sheet(isPresented: $showManuals) {
            ManualsView(vm: machineGuideVM, hermesVM: hermesVM)
        }
        .task {
            hermesVM.logVisionDiagnostics("app-launch")
            await hermesVM.refreshGlassesCameraStatus()
            await hermesVM.checkBridge()
        }
        // Pairing is the moment to ask for the glasses camera - discovering
        // it via a failed feature is how it went wrong before.
        .onChange(of: wearablesVM.registrationState) { _, state in
            guard state == .registered else { return }
            Task { await hermesVM.ensureGlassesCameraAfterPairing() }
        }
        .onChange(of: hermesVM.phoneModeActive) { _, active in
            if !active { showTranscript = false }
        }
    }

    /// What's wrong with the glasses right now, if anything. Surfaced next
    /// to the toggle rather than waiting for a feature to fail.
    private var glassesWarning: String? {
        guard hermesVM.phoneModePreference != .always else { return nil }
        if !hermesVM.glassesAvailable { return "Glasses aren't reachable" }
        // The Meta AI camera grant is a Ray-Ban thing; AiSee needs none.
        if hermesVM.glassesVendor == .meta, hermesVM.cameraPermissionGranted == false {
            return "Glasses camera isn't allowed - tap to fix"
        }
        return nil
    }

    /// Where the glasses actually stand, so the empty state can stop
    /// offering "Connect Glasses" to glasses that are already paired.
    enum GlassesSetupState {
        case ready                 // reachable, will be used
        case phoneChosen           // user picked the phone; glasses irrelevant
        case notPaired             // never registered - pairing is the fix
        case pairedButUnreachable  // registered, but no eligible device
    }

    private var glassesSetupState: GlassesSetupState {
        if hermesVM.phoneModePreference == .always { return .phoneChosen }
        if hermesVM.glassesAvailable { return .ready }
        return wearablesVM.registrationState == .registered
            ? .pairedButUnreachable : .notPaired
    }

    private var emptyStateTitle: String {
        switch glassesSetupState {
        case .ready: return "Ready to talk to \(assistantName)"
        case .phoneChosen: return "Ready when you are"
        case .notPaired: return "Connect your glasses"
        case .pairedButUnreachable: return "Your glasses aren't reachable"
        }
    }

    private var emptyStateBody: String {
        switch glassesSetupState {
        case .ready, .notPaired:
            return "\(assistantName) talks to you through your Meta Ray-Ban glasses - mic, speaker, and camera."
        case .phoneChosen:
            return "This iPhone is the eye: its camera sees for you and the lens is simulated on screen."
        case .pairedButUnreachable:
            return "They're paired but out of reach right now. Start anyway and this iPhone will be the eye."
        }
    }

    /// Open Settings with Devices already pushed.
    private func openDevices() {
        settingsRoute = .devices
        showSettings = true
    }

    /// The 5b stage owns the screen only while a phone-mode session runs and
    /// the user has not asked for the transcript.
    private var showsPhoneModeStage: Bool {
        hermesVM.phoneModeActive && !showTranscript
    }

    // MARK: - Header (brand lockup + status pills)

    @ViewBuilder
    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                HermesLockup(height: 16)

                Spacer(minLength: 4)

                // New conversation
                iconCircle("plus", label: "New conversation") {
                    hermesVM.startNewConversation()
                }
                .disabled(hermesVM.connectionState == .disconnected)
                .opacity(hermesVM.connectionState == .disconnected ? 0.4 : 1)

                iconCircle("gearshape", label: "Settings") {
                    showSettings = true
                }
            }

            HStack(spacing: 8) {
                HermesEyeToggle(
                    usesGlasses: Binding(
                        get: { hermesVM.phoneModePreference != .always },
                        set: { hermesVM.phoneModePreference = $0 ? .auto : .always }
                    ),
                    glassesWarning: glassesWarning != nil
                )
                .fixedSize()
                .disabled(hermesVM.connectionState != .disconnected)
                .opacity(hermesVM.connectionState == .disconnected ? 1 : 0.5)

                statusPills
            }

            if let glassesWarning {
                Button {
                    if hermesVM.cameraPermissionGranted == false,
                       hermesVM.glassesAvailable {
                        Task { await hermesVM.requestGlassesCameraAccess() }
                    } else {
                        openDevices()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text(glassesWarning)
                            .font(.system(size: 12, weight: .semibold))
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(HermesTheme.accentDeep)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        HermesTheme.accent.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    /// Backend and feature state, one pill each. Scrolls horizontally:
    /// the growing Recording label doesn't fit a phone width, and wrapped
    /// pill text is worse.
    private var statusPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                // Bridge reachability (or provider key status in direct mode)
                if hermesVM.backend == .direct {
                    HermesStatusPill(
                        text: hermesVM.directProvider.displayName,
                        dot: directKeyReady ? HermesTheme.online : .red,
                        tinted: directKeyReady
                    )
                } else {
                    Button {
                        Task { await hermesVM.checkBridge() }
                    } label: {
                        HermesStatusPill(
                            text: "Bridge",
                            dot: bridgeDotColor,
                            tinted: hermesVM.bridgeStatus == .reachable
                        )
                    }
                    .buttonStyle(.plain)
                }

                // AiSee has no lens: a HUD chip there reports a setting that
                // cannot do anything, next to glasses that have no display.
                if hermesVM.glassesSupportsDisplay {
                    HermesStatusPill(
                        text: hermesVM.displayHUDEnabled ? "HUD on" : "HUD off",
                        tinted: hermesVM.displayHUDEnabled
                    )
                }

                // Live capture indicator. The entry point is the Record quick
                // action below - this only earns its place while a capture is
                // running, when the snap count is worth seeing.
                // This pill only ever renders while a capture is running -
                // `conversationCaptureActive` gates the `if` above, so the
                // three ternaries this used to carry were always the same
                // branch.
                if hermesVM.socialNotesEnabled,
                   hermesVM.conversationCaptureActive {
                    Button {
                        hermesVM.toggleConversationCapture()
                    } label: {
                        HermesStatusPill(
                            text: recordingPillLabel,
                            dot: .red,
                            icon: hermesVM.conversationCaptureSnapCount > 0
                                ? "camera.fill" : nil,
                            tinted: true
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 1)
        }
        .scrollClipDisabled()
    }

    private var recordingPillLabel: String {
        let snaps = hermesVM.conversationCaptureSnapCount
        return snaps == 0 ? "Recording…" : "Recording… \(snaps)"
    }

    private func iconCircle(
        _ systemName: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Color.secondary.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var directKeyReady: Bool {
        !hermesVM.directProvider.requiresKey || hermesVM.hasDirectKey
    }

    private var bridgeDotColor: Color {
        switch hermesVM.bridgeStatus {
        case .reachable: return HermesTheme.online
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

                        // LIVE transcription - words appear as you speak
                        if !hermesVM.liveTranscript.isEmpty {
                            liveTranscriptBubble
                        }

                        // Options offered by the latest reply, answerable
                        // by tapping rather than by saying the letter back.
                        if !hermesVM.replyChoices.isEmpty {
                            choiceChips
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
                    .kerning(-0.3)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.secondary.opacity(0.1), in: userBubbleShape)
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
            .accessibilityLabel("Send now")
        }
    }

    /// Mirrors the buttons the wearer gets on the lens.
    private var choiceChips: some View {
        FlowRow(spacing: 8) {
            ForEach(hermesVM.replyChoices) { choice in
                Button {
                    hermesVM.chooseReplyOption(choice)
                } label: {
                    Text(choice.label)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(HermesTheme.accentOnCard)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(HermesTheme.accent.opacity(0.12), in: Capsule())
                        .overlay {
                            Capsule().strokeBorder(
                                HermesTheme.accent.opacity(0.3), lineWidth: 1
                            )
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 2)
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            Spacer()

            HermesLockup(height: 26, showsSuffix: true)

            VStack(spacing: 8) {
                Text(emptyStateTitle)
                    .font(.system(size: 28, weight: .bold))
                    .kerning(-0.5)
                    .multilineTextAlignment(.center)

                Text(emptyStateBody)
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            switch glassesSetupState {
            case .ready, .phoneChosen:
                EmptyView()
            case .notPaired:
                HermesPrimaryButton(title: "Connect Glasses") {
                    wearablesVM.connectGlasses()
                }
                .padding(.horizontal, 24)
                Text("You'll finish pairing in the Meta AI app.")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            case .pairedButUnreachable:
                // Already registered: offering "Connect Glasses" here just
                // produced "User is already registered". Re-pairing lives in
                // Settings, so send them there.
                HermesPrimaryButton(title: "Manage glasses", systemImage: "gearshape") {
                    openDevices()
                }
                .padding(.horizontal, 24)
                Text("Wake the glasses or put them on. If they still don't appear, re-pair them in Devices.")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Bubbles

    struct UserBubble: View {
        let text: String

        var body: some View {
            HStack {
                Spacer(minLength: 60)
                Text(text)
                    .font(.system(size: 16))
                    .kerning(-0.3)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(HermesTheme.accent, in: userBubbleShape)
            }
        }
    }

    struct AssistantBubble: View {
        let text: String

        var body: some View {
            HStack {
                Text(text)
                    .font(.system(size: 16))
                    .kerning(-0.3)
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        HermesTheme.card,
                        in: UnevenRoundedRectangle(
                            topLeadingRadius: 20, bottomLeadingRadius: 6,
                            bottomTrailingRadius: 20, topTrailingRadius: 20
                        )
                    )
                    .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
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
                        PhotoCard(image: image, source: turn.photoSource ?? GlassesVendor.meta.cameraLabel)
                    }
                }

                UserBubble(text: turn.userText)
                AssistantBubble(text: turn.agentText)
            }
        }
    }

    /// Captured photo with a caption bar naming the camera that took it
    struct PhotoCard: View {
        let image: UIImage
        var source: String = GlassesVendor.meta.cameraLabel

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
                    Text(source)
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(HermesTheme.card)
            }
            .frame(width: 200)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
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
            return "\(assistantName) speaking through \(device) - tap to stop"
        }
        return "\(assistantName) is speaking - tap to stop"
    }

    // MARK: - Quick actions

    /// The four feature screens, one tap from the conversation. Lens is
    /// the only one that needs the glasses; the rest read stored data.
    private var quickActions: some View {
        VStack(spacing: 6) {
            // Grab handle: the row is the top of a drawer, not the whole
            // set. Dragging up opens everything.
            Capsule()
                .fill(Color.secondary.opacity(0.25))
                .frame(width: 36, height: 4)
                .contentShape(Rectangle().inset(by: -12))
                .onTapGesture { showAppDrawer = true }

            // The row scrolls horizontally: five apps plus Record outgrew
            // one screen width, and shrinking the tiles to fit would have
            // made every target smaller to keep a rarely-used one visible.
            // More sits OUTSIDE the scroll, always on screen: the drawer used
            // to be reachable only through the grab handle above, a gesture
            // nobody was told about, so apps that lived there went unfound.
            HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // Record is an action, not a screen, so it is deliberately
                    // NOT a HermesApp - it has no presentation and nothing to
                    // open. It sits here because this row is where people look
                    // for features, and recording a conversation used to be
                    // reachable only from a chip that appeared after a voice
                    // session was already running.
                    if hermesVM.socialNotesEnabled {
                        recordQuickAction
                    }
                    ForEach(HermesAppRegistry.pinned) { app in
                        quickAction(app)
                    }
                }
                .padding(.leading, 16)
            }
            moreQuickAction
                .padding(.trailing, 16)
            }
        }
        .padding(.bottom, 10)
        .gesture(
            DragGesture(minimumDistance: 12)
                .onEnded { value in
                    if value.translation.height < -20 { showAppDrawer = true }
                }
        )
    }

    /// Why this app can't be opened right now, or nil. Stated in the drawer
    /// instead of letting the tap fail.
    private func unavailableReason(_ app: HermesApp) -> String? {
        if app.capabilities.contains(.vision), !hermesVM.canStartSession {
            return "Needs a camera - no glasses, and phone mode is off."
        }
        return nil
    }

    /// The one choke point for the drawer and the quick actions. Lens and
    /// Lookup open their own camera stream; during a Build Check run the
    /// run owns the camera, so they are refused rather than left to take
    /// it (the run would log a frozen frame).
    private func open(_ app: HermesApp) {
        // First open clears the app's "New" dot and its What's-new card.
        var opened = openedAppIDs
        if opened.insert(app.id).inserted {
            appsOpenedRaw = HermesAppRegistry.idString(opened)
        }
        if hermesVM.buildRunClaimer != nil, app.id == "lens" || app.id == "lookup" {
            hermesVM.showNoticeMessage(
                "End the build check before opening \(app.id == "lens" ? "Lens" : "Lookup").")
            return
        }
        switch app.id {
        case "lens": showLens = true
        case "people": showPeople = true
        case "map": showMap = true
        case "log": showObjectLog = true
        case "lookup": showLookup = true
        case "buildcheck": showBuildCheck = true
        case "manuals": showManuals = true
        default: break
        }
    }

    /// Start/stop a conversation capture from a cold start.
    ///
    /// `toggleConversationCapture` brings up the microphone itself when
    /// nothing is running, so this tile never needs a session first.
    private var recordQuickAction: some View {
        Button {
            hermesVM.toggleConversationCapture()
        } label: {
            VStack(spacing: 5) {
                Image(
                    systemName: hermesVM.conversationCaptureActive
                        ? "stop.circle.fill" : "waveform.circle"
                )
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(
                    hermesVM.conversationCaptureActive ? .red : HermesTheme.accent
                )
                Text(hermesVM.conversationCaptureActive ? "Stop" : "Record")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(HermesTheme.inkSoft)
            }
            // Fixed width: inside the scrollable row, maxWidth .infinity
            // would collapse each tile to its label's width.
            .frame(width: quickActionTileWidth)
            .padding(.vertical, 10)
            .background(
                hermesVM.conversationCaptureActive
                    ? Color.red.opacity(0.12) : HermesTheme.card,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
        }
        .buttonStyle(.plain)
    }

    /// Wide enough for the longest tile label ("Lookup") without shrinking
    /// the tap target; five tiles at this width overflow the screen, which
    /// is what the row's horizontal scroll is for.
    private let quickActionTileWidth: CGFloat = 72

    private func quickAction(_ app: HermesApp) -> some View {
        let blocked = unavailableReason(app) != nil
        return quickAction(app.title, icon: app.systemImage, enabled: !blocked,
                           isNew: unseenNewAppIDs.contains(app.id)) {
            open(app)
        }
    }

    /// Opens the drawer. Carries the "New" dot when a new app is in there.
    private var moreQuickAction: some View {
        let pinnedIDs = Set(HermesAppRegistry.pinned.map(\.id))
        let newInDrawer = !unseenNewAppIDs.subtracting(pinnedIDs).isEmpty
        return quickAction("More", icon: "square.grid.2x2", isNew: newInDrawer) {
            showAppDrawer = true
        }
    }

    private func quickAction(
        _ title: String,
        icon: String,
        enabled: Bool = true,
        isNew: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(HermesTheme.accent)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(HermesTheme.inkSoft)
            }
            .frame(width: quickActionTileWidth)
            .padding(.vertical, 10)
            .background(
                HermesTheme.card,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .shadow(color: .black.opacity(0.04), radius: 1, y: 1)
            .overlay(alignment: .topTrailing) {
                if isNew { NewDot().offset(x: -6, y: 6) }
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }

    // MARK: - Bottom Bar (waveform + End / Start)

    @ViewBuilder
    private var bottomBar: some View {
        Group {
            if hermesVM.connectionState == .disconnected {
                VStack(spacing: 8) {
                    HermesPrimaryButton(
                        title: startButtonTitle,
                        systemImage: "mic",
                        enabled: hermesVM.canStartSession
                    ) {
                        Task { await hermesVM.startSession() }
                    }
                    if let note = startButtonNote {
                        Text(note)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 14)
            } else {
                listeningBar
            }
        }
    }

    /// Live session bar: the waveform, what Hermes is doing, and the way
    /// out. The label doubles as the mic-source switch - it's the only
    /// place the current mic is named, so it's where a tap to change it
    /// belongs.
    private var listeningBar: some View {
        HStack(spacing: 12) {
            Button {
                Task { await hermesVM.toggleMicSource() }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    WaveformView(
                        level: hermesVM.micLevel,
                        accent: isErrorState ? HermesTheme.destructive : HermesTheme.accent,
                        barCount: 22
                    )
                    Text(bottomStatusLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(bottomStatusStyle)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            HermesDestructiveButton(title: "End", height: 40) {
                hermesVM.endSession()
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .background(alignment: .top) {
            VStack(spacing: 0) {
                HermesDivider()
                // The phone-mode stage above is always dark chrome; a cream
                // bar under it would read as a different app.
                (showsPhoneModeStage
                    ? HermesTheme.cream.opacity(0.06)
                    : HermesTheme.card.opacity(0.7))
            }
        }
    }

    private var startButtonTitle: String { "Start listening" }

    /// Only says something the toggle above doesn't already say.
    private var startButtonNote: String? {
        if !hermesVM.canStartSession {
            return "No glasses, and phone mode is off. Turn it on in Settings → Devices."
        }
        // Glasses chosen but unreachable: the fallback is about to happen and
        // the user should not be surprised by it.
        if hermesVM.phoneModePreference != .always, !hermesVM.glassesAvailable {
            return "Glasses aren't reachable - this iPhone will be the eye."
        }
        return nil
    }

    private var bottomStatusStyle: AnyShapeStyle {
        if isErrorState { return AnyShapeStyle(HermesTheme.destructive) }
        return showsPhoneModeStage
            ? AnyShapeStyle(HermesTheme.cream.opacity(0.5))
            : AnyShapeStyle(Color.secondary)
    }

    private var isErrorState: Bool {
        if case .error = hermesVM.connectionState { return true }
        return false
    }

    /// State line under the waveform. Also names the mic, since tapping
    /// here switches it.
    private var bottomStatusLabel: String {
        // The note capture overrides the generic states - it's the one time
        // the user needs to know exactly what's being listened for.
        if hermesVM.awaitingEncounterNote {
            return "Say a note about this person"
        }
        let mic = "\(hermesVM.micSource.shortLabel) mic · tap to switch"
        switch hermesVM.connectionState {
        case .disconnected: return mic
        case .connecting: return "Connecting…"
        case .listening, .recording:
            return hermesVM.phoneModeActive
                ? "Listening · phone mode" : "Listening · \(mic)"
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

// MARK: - Flow layout

/// Wrapping horizontal stack. Choice labels vary from "Yes" to a short
/// sentence, so a fixed HStack would clip them.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + lineHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize,
        subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Waveform

/// Mic-level waveform: bars with a sine envelope, per the design
struct WaveformView: View {
    let level: Float
    let accent: Color
    /// 30 reads as a full-width meter; 8 fits inside a compact card.
    var barCount: Int = 30

    var body: some View {
        HStack(spacing: 3.5) {
            ForEach(0..<barCount, id: \.self) { i in
                // Sine envelope so the run tapers at both ends, floored at
                // half so the outermost bars stay visible rather than
                // collapsing to dots.
                let env = sin(Double(i) / Double(barCount - 1) * .pi)
                let taper = 0.5 + 0.5 * env
                // Fixed per-bar resting heights (5–16pt, as in the design):
                // a silent room still reads as a waveform, not a dotted line.
                let resting = 5 + 11 * abs(sin(Double(i) * 2.7 + 1.3))
                Capsule()
                    .fill(accent.opacity(0.45 + 0.55 * env))
                    .frame(
                        width: 3,
                        height: max(3, resting * taper + 22 * amplitude * env)
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

/// AiSee video clip status: "Starting…" (with the Wi-Fi join hint, since the
/// glasses stream over their own hotspot and iOS asks to join it) or a
/// running timer with Stop.
private struct ClipStatusBanner: View {
    let hermesVM: HermesSessionViewModel

    var body: some View {
        HStack(spacing: 10) {
            if hermesVM.clipRecording, let started = hermesVM.clipStartedAt {
                Circle().fill(HermesTheme.destructive).frame(width: 10, height: 10)
                TimelineView(.periodic(from: started, by: 1)) { context in
                    let seconds = max(0, Int(context.date.timeIntervalSince(started)))
                    Text("Recording video  \(seconds / 60):\(String(format: "%02d", seconds % 60))")
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                }
                Spacer(minLength: 8)
                Button("Stop") { Task { await hermesVM.toggleClipRecording() } }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(HermesTheme.destructive)
            } else {
                ProgressView()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Starting video clip…")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Your iPhone may ask to join the glasses' Wi-Fi - tap Join. The video streams over it.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(HermesTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }
}

/// The "not opened yet" marker: one accent dot, the app's only colour.
struct NewDot: View {
    var body: some View {
        Circle()
            .fill(HermesTheme.accent)
            .frame(width: 8, height: 8)
            .accessibilityLabel("New")
    }
}

/// One-time announcement of a new app. Open clears it (and the dot);
/// the close button hides the card but leaves the dot until first open.
private struct WhatsNewCard: View {
    let app: HermesApp
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            HermesIconTile(systemName: app.systemImage, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("New")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(HermesTheme.accentOnCard)
                    Text(app.title)
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(app.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open \(app.title)", action: onOpen)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(HermesTheme.accentOnCard)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(14)
        .background(HermesTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }
}
