//
// SettingsView.swift
//
// Settings as a hub of sub-pages rather than one long scroll (see
// docs/superpowers/specs/2026-07-20-settings-redesign-design.md), styled
// to screen 4b of the UI design: a warm-black device card on top, then
// grouped terracotta-tiled rows - ONE accent, never a rainbow of system
// colours.
//
// Turn 5 of the design adds two pages here: Devices (5a), which lists
// what's paired plus what's coming with capability chips, and Developer
// (5d), which now owns the subsystem test panel that used to float over
// the session screen.
//
// Text the user types (bridge endpoint, API key) is owned HERE and passed
// down by binding, so the existing "swipe-dismiss must not discard typed
// values" contract still holds no matter which sub-page is open.
//

import SwiftUI

/// Sub-pages that can be opened directly from elsewhere in the app.
enum SettingsRoute: Hashable {
    case devices
    case roster
}

struct SettingsView: View {
    let hermesVM: HermesSessionViewModel
    let wearablesVM: WearablesViewModel
    /// Push this page as soon as Settings appears.
    var initialRoute: SettingsRoute? = nil

    @State private var path: [SettingsRoute] = []

    @State private var endpoint: String = ""
    @State private var providerKey: String = ""
    @State private var showObjectLog: Bool = false
    /// Held as state rather than built per render: the store reads its index
    /// off disk on init, and the roster row asks for `count` every redraw.
    @State private var rosterStore = RosterStore()
    /// Seeds `endpoint` exactly once. Without this, popping back from any
    /// sub-page re-runs the root's `onAppear` and overwrites whatever the
    /// Assistant page has in flight, discarding it before Done (or
    /// swipe-dismiss) can commit it - `providerKey` is never reset this way,
    /// which is what gave the bug away.
    @State private var didLoadEndpoint = false
    /// Consumes `initialRoute` exactly once. Without this, popping back to
    /// an empty `path` re-runs `onAppear` and re-pushes the same route,
    /// trapping the user on that page - Back never actually goes back.
    @State private var didConsumeInitialRoute = false
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw =
        AppearanceMode.system.rawValue
    @Environment(\.dismiss) private var dismiss

    private var appearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }

    var body: some View {
        NavigationStack(path: $path) {
            HermesScrollPage {
                NavigationLink(value: SettingsRoute.devices) {
                    HermesDeviceCard(
                        title: deviceTitle,
                        status: deviceStatus,
                        dot: deviceDotConnected ? HermesTheme.online : .gray
                    ) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(HermesTheme.cream.opacity(0.35))
                    }
                }
                .buttonStyle(.plain)

                HermesSection {
                    navRow("Assistant", icon: "brain", value: assistantValue) {
                        AssistantPage(
                            hermesVM: hermesVM,
                            endpoint: $endpoint,
                            providerKey: $providerKey
                        )
                    }
                    HermesDivider()
                    navRow("Voice & Microphone", icon: "mic",
                           value: hermesVM.micSource.shortLabel) {
                        VoicePage(
                            hermesVM: hermesVM,
                            // Unknown (nothing paired) counts as Display, so
                            // the warning is never withheld from someone it
                            // applies to.
                            glassesHaveDisplay: wearablesVM.glasses.isEmpty
                                || wearablesVM.glasses.contains(where: \.supportsDisplay)
                        )
                    }
                    // AiSee has no lens - the whole row (and the HUD
                    // settings behind it) is meaningless for that vendor.
                    if hermesVM.glassesSupportsDisplay {
                        HermesDivider()
                        navRow("Glasses Display", icon: "eyeglasses",
                               value: hermesVM.displayHUDEnabled ? "On" : "Off") {
                            DisplayPage(hermesVM: hermesVM)
                        }
                    }
                    HermesDivider()
                    navRow("Appearance", icon: "circle.lefthalf.filled",
                           value: appearance.label) {
                        AppearancePage()
                    }
                }

                HermesSection {
                    navRow("People", icon: "person.crop.circle",
                           value: hermesVM.socialNotesEnabled ? "On" : "Off") {
                        PeoplePage(hermesVM: hermesVM)
                    }
                    HermesDivider()
                    navRow("People roster", icon: "person.text.rectangle",
                           value: "\(rosterStore.count)") {
                        RosterView(store: rosterStore)
                    }
                    HermesDivider()
                    // Object Log owns its own NavigationStack + Done button,
                    // so it's presented, not pushed.
                    Button {
                        showObjectLog = true
                    } label: {
                        HermesRow(
                            "Object Log",
                            icon: "camera.viewfinder",
                            value: "\(hermesVM.allLensSessions().count)"
                        )
                    }
                    .buttonStyle(.plain)
                    HermesDivider()
                    navRow("Navigation & Maps", icon: "mappin.and.ellipse",
                           value: hermesVM.navigationEnabled ? "On" : "Off") {
                        NavigationPage(hermesVM: hermesVM)
                    }
                    HermesDivider()
                    navRow("Context & Privacy", icon: "lock",
                           value: hermesVM.contextEnabled ? "Sharing" : "Off") {
                        ContextPage(hermesVM: hermesVM)
                    }
                }

                // Testers land here first: everything you can say, in one
                // place, generated from the detectors themselves.
                HermesSection {
                    navRow("What can I say?", icon: "text.bubble", value: nil) {
                        VoiceCommandsPage()
                    }
                    HermesDivider()
                    navRow("Developer", icon: "wrench.and.screwdriver",
                           mutedIcon: true, value: "Test panel") {
                        DeveloperPage(hermesVM: hermesVM)
                    }
                }

                VStack(spacing: 4) {
                    HermesLockup(height: 13, showsSuffix: true)
                    Text("Version \(Self.appVersion) · talk to your AI from your Meta Ray-Ban glasses.")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(HermesTheme.groupedCanvas, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        commitTypedValues()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .devices:
                    DevicesPage(hermesVM: hermesVM, wearablesVM: wearablesVM)
                case .roster:
                    RosterView(store: rosterStore)
                }
            }
            .onAppear {
                if !didLoadEndpoint {
                    didLoadEndpoint = true
                    endpoint = hermesVM.hermesEndpoint
                }
                if !didConsumeInitialRoute, let initialRoute {
                    didConsumeInitialRoute = true
                    path = [initialRoute]
                }
            }
            .onDisappear(perform: commitTypedValues)
            .sheet(isPresented: $showObjectLog) {
                ObjectLogView(hermesVM: hermesVM)
            }
        }
        .tint(HermesTheme.accent)
    }

    // MARK: - Hub rows

    private func navRow<Destination: View>(
        _ title: String,
        icon: String,
        mutedIcon: Bool = false,
        value: String?,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HermesRow(title, icon: icon, mutedIcon: mutedIcon, value: value)
        }
        .buttonStyle(.plain)
    }

    /// Read from the bundle rather than hard-coded, so the footer can't
    /// drift from what was actually shipped.
    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var deviceTitle: String {
        switch hermesVM.glassesVendor {
        case .meta:
            return wearablesVM.glasses.first?.name ?? "Ray-Ban Display"
        case .aisee:
            if case .connected(let name) = hermesVM.aisee.state { return name }
            return hermesVM.glassesVendor.label
        }
    }

    /// The dot must answer the same question `deviceStatus` does. Neither
    /// vendor may use `isGlassesConnected` for it - that only goes true once a
    /// session has claimed the glasses, so glasses that were in range and
    /// ready showed "Not connected" beside a grey dot until Start listening.
    /// Meta's answer is the SDK's own selector (`activeGlassesDevice`), the
    /// same predicate `createSession` resolves through; AiSee's is the kit's
    /// link.
    private var deviceDotConnected: Bool {
        switch hermesVM.glassesVendor {
        case .meta: return hermesVM.metaGlassesReachable
        case .aisee: return hermesVM.aisee.state.isConnected
        }
    }

    private var deviceStatus: String {
        switch hermesVM.glassesVendor {
        case .meta:
            let connection = hermesVM.isGlassesConnected
                ? "In use"
                : hermesVM.metaGlassesReachable ? "Connected" : "Not connected"
            let count = wearablesVM.devices.count
            return "\(connection) · \(count) device\(count == 1 ? "" : "s")"
        case .aisee:
            // The Meta device list says nothing about AiSee - it pairs over
            // its own Bluetooth link, so its own state is the status. Reading
            // `wearablesVM.devices.count` here reported "0 devices" beside a
            // connected pair of AiSee glasses.
            switch hermesVM.aisee.state {
            case .connected:
                guard let battery = hermesVM.aisee.battery else { return "Connected" }
                return "Connected · \(battery)%"
            case .connecting: return "Connecting…"
            case .scanning: return "Scanning…"
            case .disconnected: return "Not connected"
            }
        }
    }

    private var assistantValue: String {
        guard hermesVM.backend == .direct else { return "Bridge" }
        let model = hermesVM.directProvider.curatedModels
            .first { $0.id == hermesVM.directModel }?.label
        guard let model else { return hermesVM.directProvider.displayName }
        // "Direct · Opus" - provider is implied by the model name.
        return "Direct · \(model)"
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

// MARK: - Devices (5a)

/// Hardware is a list, not a fact: what's paired, what the phone can
/// stand in for, and what's coming. Capability chips - not model names -
/// are what the rest of the app switches on.
private struct DevicesPage: View {
    let hermesVM: HermesSessionViewModel
    let wearablesVM: WearablesViewModel

    /// Models the DAT SDK doesn't reach yet. Listed so the shape of the
    /// screen doesn't change when one of them lands.
    private static let upcoming: [(name: String, detail: String)] = [
        ("Even Realities G1", "Green HUD · no camera"),
        ("Even Realities G2", "Display · camera · audio"),
        ("Brilliant Labs Halo", "Display · camera · open SDK"),
        ("XREAL One", "Large display · tethered"),
    ]

    var body: some View {
        HermesScrollPage {
            vendorSection

            if hermesVM.glassesVendor == .meta {
                metaDeviceSection
                cameraPermissionSection
            } else {
                aiseeCard
            }

            phoneModeSection

            if hermesVM.glassesVendor == .aisee {
                aiseeConnectionSection
                aiseeButtonsSection
            }

            if hermesVM.glassesVendor == .meta {
                if !wearablesVM.glasses.isEmpty {
                    pairedSection
                }
                upcomingSection
            }
        }
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Vendor

    /// Which glasses "glasses" means, for both the camera route and the
    /// mic-source list. Switching ends any live session (Hermes Session VM).
    private var vendorSection: some View {
        HermesSection(
            header: "Glasses",
            footer: "Switching brands ends any session in progress."
        ) {
            Picker("Glasses vendor", selection: Binding(
                get: { hermesVM.glassesVendor },
                set: { hermesVM.glassesVendor = $0 }
            )) {
                ForEach(GlassesVendor.allCases) { vendor in
                    Text(vendor.label).tag(vendor)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    // MARK: - Meta (unchanged from before the vendor picker)

    @ViewBuilder
    private var metaDeviceSection: some View {
        if let active = wearablesVM.glasses.first {
            HermesDeviceCard(
                title: active.name,
                status: hermesVM.isGlassesConnected
                    ? "In use"
                    : hermesVM.metaGlassesReachable
                        ? "Connected" : "Paired · not connected",
                dot: hermesVM.metaGlassesReachable
                    ? HermesTheme.online : .gray,
                chips: active.capabilities
            ) {
                NavigationLink {
                    GlassesStatusPage(
                        hermesVM: hermesVM, wearablesVM: wearablesVM
                    )
                } label: {
                    Text("Manage")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(HermesTheme.cream)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(HermesTheme.cream.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        } else {
            HermesSection(
                header: "No glasses paired",
                footer: "Pairing finishes in the Meta AI app."
            ) {
                Button {
                    wearablesVM.connectGlasses()
                } label: {
                    HermesRow(
                        "Connect glasses",
                        icon: "eyeglasses",
                        value: registrationText
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var cameraPermissionSection: some View {
        HermesSection(
            header: "Glasses camera",
            footer: "Meta AI grants the glasses camera separately from iOS. Without it, Lens and \"remember this person\" get no picture - the most common reason a photo goes missing."
        ) {
            Button {
                Task { await hermesVM.requestGlassesCameraAccess() }
            } label: {
                HermesRow(
                    title: "Camera access",
                    showsChevron: false
                ) {
                    switch hermesVM.cameraPermissionGranted {
                    case .some(true):
                        HermesBadge(text: "Allowed", prominent: true)
                    case .some(false), .none:
                        Text("Allow")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(HermesTheme.accentOnCard)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var pairedSection: some View {
        HermesSection(header: "Paired") {
            ForEach(Array(wearablesVM.glasses.enumerated()), id: \.element.id) { index, device in
                if index > 0 { HermesDivider() }
                pairedRow(device)
            }
        }
    }

    private var upcomingSection: some View {
        HermesSection(
            header: "Add glasses",
            footer: "Hermes adapts to whatever the device can do - features switch off, screens don't disappear."
        ) {
            ForEach(Array(Self.upcoming.enumerated()), id: \.element.name) { index, model in
                if index > 0 { HermesDivider() }
                HermesRow(
                    title: model.name,
                    subtitle: model.detail,
                    showsChevron: false
                ) {
                    HermesBadge(text: "Soon")
                }
                .opacity(0.6)
            }
        }
    }

    // MARK: - AiSee

    /// Warm-black hero card, matching the Meta paired-device card's visual
    /// language: status dot, name once connected, capability chips. AiSee
    /// has no lens, so "No display" is always the third chip.
    private var aiseeCard: some View {
        HermesDeviceCard(
            title: aiseeTitle,
            status: aiseeStatusText,
            dot: aiseeDotColor,
            chips: [
                ("Camera", true),
                ("Audio", true),
                ("No display", false),
            ]
        )
    }

    private var aiseeTitle: String {
        if case .connected(let name) = hermesVM.aisee.state { return name }
        return "AiSee Glasses"
    }

    private var aiseeDotColor: Color {
        switch hermesVM.aisee.state {
        case .connected: return HermesTheme.online
        case .scanning, .connecting: return .orange
        case .disconnected: return .gray
        }
    }

    private var aiseeStatusText: String {
        switch hermesVM.aisee.state {
        case .connected:
            guard let battery = hermesVM.aisee.battery else { return "Connected" }
            return "Connected · \(battery)%"
        case .scanning: return "Scanning…"
        case .connecting: return "Connecting…"
        case .disconnected: return "Not connected"
        }
    }

    /// Scan / discovered-device list while unpaired, refresh-battery /
    /// disconnect once the link is up. AiSee has no Meta AI app step - this
    /// card is the whole pairing flow.
    /// The glasses have one button; firmware reports tap / double / triple as
    /// keys 1 / 2 / 3. Map each to an action.
    private var aiseeButtonsSection: some View {
        HermesSection(
            header: "Button",
            footer: "The glasses tell Hermes whether you tapped, double-tapped or triple-tapped. Developer › AiSee button shows the last one received. A video clip streams over the glasses' own Wi-Fi - the first time, your iPhone asks to join it."
        ) {
            ForEach(GlassesKeyMap.keys, id: \.self) { key in
                let selection = Binding(
                    get: { hermesVM.glassesKeyMap.action(forKey: key) },
                    set: { hermesVM.glassesKeyMap.set($0, forKey: key) }
                )
                // A Menu with a one-line label, not an inline Picker: the
                // picker's own label wrapped long action names onto two lines
                // and spilled out of the row.
                Menu {
                    Picker("", selection: selection) {
                        ForEach(GlassesKeyAction.allCases) { action in
                            Text(action.label).tag(action)
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text(GlassesKeyMap.label(forKey: key))
                            .font(.system(size: 17))
                            .foregroundStyle(.primary)
                            .fixedSize()
                        Spacer(minLength: 8)
                        Text(selection.wrappedValue.label)
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(minHeight: 52)
                    .contentShape(Rectangle())
                }
                .padding(.horizontal, 16)
                if key != GlassesKeyMap.keys.last { HermesDivider() }
            }
        }
    }

    private var aiseeConnectionSection: some View {
        HermesSection(
            header: "AiSee connection",
            footer: "AiSee glasses pair directly over Bluetooth - no Meta AI app needed. Camera and audio work today; the lens has no display."
        ) {
            if hermesVM.aisee.state.isConnected {
                HermesRow(
                    "Battery",
                    icon: "battery.100",
                    value: hermesVM.aisee.battery.map { "\($0)%" } ?? "—",
                    showsChevron: false
                )
                HermesDivider()
                Button {
                    Task { await hermesVM.aisee.refreshBattery() }
                } label: {
                    HermesRow(title: "Refresh battery", showsChevron: false) {
                        Text("Refresh")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(HermesTheme.accentOnCard)
                    }
                }
                .buttonStyle(.plain)
                HermesDivider()
                Button {
                    hermesVM.aisee.disconnect()
                } label: {
                    HermesRow(title: "Disconnect", showsChevron: false) {
                        Text("Disconnect")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(HermesTheme.destructive)
                    }
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    if case .scanning = hermesVM.aisee.state {
                        hermesVM.aisee.stopScan()
                    } else {
                        hermesVM.aisee.startScan()
                    }
                } label: {
                    HermesRow(
                        title: aiseeScanButtonTitle,
                        // The row is disabled without Bluetooth (see
                        // `aiseeScanDisabled`); say why, or it reads as broken.
                        subtitle: hermesVM.aisee.bluetoothReady
                            ? nil : "Bluetooth unavailable",
                        showsChevron: false
                    ) {
                        if case .connecting = hermesVM.aisee.state {
                            ProgressView().scaleEffect(0.7)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(aiseeScanDisabled)
                .opacity(aiseeScanDisabled ? 0.5 : 1)

                if !hermesVM.aisee.discovered.isEmpty {
                    ForEach(hermesVM.aisee.discovered) { device in
                        HermesDivider()
                        Button {
                            hermesVM.aisee.connect(device.id)
                        } label: {
                            HermesRow(
                                title: device.name,
                                subtitle: device.rssi == 0 ? "Paired" : "\(device.rssi) dBm",
                                showsChevron: false
                            ) {
                                Text("Connect")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(HermesTheme.accentOnCard)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var aiseeScanButtonTitle: String {
        switch hermesVM.aisee.state {
        case .scanning: return "Stop scan"
        default: return "Scan for AiSee glasses"
        }
    }

    /// Bluetooth not ready can't scan at all; already `.connecting` shouldn't
    /// be interrupted by a fresh `startScan()` from a stray tap.
    private var aiseeScanDisabled: Bool {
        guard hermesVM.aisee.bluetoothReady else { return true }
        if case .connecting = hermesVM.aisee.state { return true }
        return false
    }

    // MARK: - Shared (both vendors)

    private var phoneModeSection: some View {
        HermesSection(
            header: "No glasses on you?",
            footer: hermesVM.phoneModePreference.explanation
        ) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("Use this iPhone")
                            .font(.system(size: 16, weight: .semibold))
                        if hermesVM.visionRoute == .phone {
                            HermesBadge(text: "Active", prominent: true)
                        }
                    }
                    Text("Phone camera as the eye, simulated lens on screen")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Picker("Phone mode", selection: Binding(
                    get: { hermesVM.phoneModePreference },
                    set: { hermesVM.phoneModePreference = $0 }
                )) {
                    ForEach(PhoneModePreference.allCases) { preference in
                        Text(preference.label).tag(preference)
                    }
                }
                .pickerStyle(.segmented)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            HermesDivider()

            HStack(spacing: 8) {
                HermesChip(text: "Camera")
                HermesChip(text: "Audio")
                HermesChip(text: "Simulated display", available: false)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func pairedRow(_ device: GlassesDevice) -> some View {
        HStack(spacing: 12) {
            HermesIconTile(systemName: "eyeglasses", size: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(device.name)
                    .font(.system(size: 16))
                    .kerning(-0.4)
                HStack(spacing: 5) {
                    ForEach(device.capabilitySummary, id: \.label) { chip in
                        HermesChip(text: chip.label, available: chip.available, size: 10)
                    }
                }
            }
            Spacer(minLength: 8)
            Text(device.isConnected ? "On" : "Off")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var registrationText: String {
        switch wearablesVM.registrationState {
        case .notRegistered: return "Not paired"
        case .registering: return "Pairing…"
        case .registered: return "Paired"
        case .unavailable: return "Unavailable"
        }
    }
}

// MARK: - Glasses status

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
                Text("0 devices with \"Registered\" means the glasses aren't reachable over Bluetooth right now, or the pairing is stale. Camera permission is requested via the Meta AI app as soon as the glasses pair - re-request it from Devices → Camera access.")
            }

            Section {
                Button("Re-pair Glasses", role: .destructive) {
                    Task { await wearablesVM.repairGlasses() }
                }
            }
        }
        .hermesFormStyle()
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
        case .some(false): return "Denied - go back to Devices and tap Allow under Camera access"
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

// MARK: - Assistant (5c)

/// Direct API is the default brain; the Mac bridge drops to an advanced
/// route that needs a machine awake on the same network.
private struct AssistantPage: View {
    let hermesVM: HermesSessionViewModel
    @Binding var endpoint: String
    @Binding var providerKey: String

    @State private var showSavePreset: Bool = false
    @State private var presetName: String = ""
    @State private var presetsVersion: Int = 0  // bump to refresh list

    var body: some View {
        HermesScrollPage {
            HermesSection(header: "Brain") {
                brainRow(
                    .direct,
                    title: "Direct API",
                    badge: "Default",
                    prominent: true,
                    detail: "Straight to \(hermesVM.directProvider.displayName) · works anywhere"
                )
                HermesDivider()
                brainRow(
                    .bridge,
                    title: "Mac bridge",
                    badge: "Advanced",
                    prominent: false,
                    detail: "Tools + local files · needs your Mac awake"
                )
            }

            if hermesVM.backend == .direct {
                directSection
            } else {
                bridgeSection
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
            .disabled(presetName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saves the current URL so you can switch with one tap.")
        }
    }

    // MARK: Brain selector

    private func brainRow(
        _ backend: AssistantBackend,
        title: String,
        badge: String,
        prominent: Bool,
        detail: String
    ) -> some View {
        let selected = hermesVM.backend == backend
        return Button {
            hermesVM.backend = backend
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: 16, weight: selected ? .semibold : .regular))
                            .foregroundStyle(.primary)
                        HermesBadge(text: badge, prominent: prominent)
                    }
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 19))
                        .foregroundStyle(HermesTheme.accent)
                } else {
                    Circle()
                        .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1.5)
                        .frame(width: 19, height: 19)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 62)
            .background(
                selected ? HermesTheme.accent.opacity(0.06) : .clear
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Direct

    @ViewBuilder
    private var directSection: some View {
        HermesSection(
            footer: "Direct mode needs no server - the phone calls \(hermesVM.directProvider.displayName) with your key. Applies from the next session."
        ) {
            Menu {
                Picker("Provider", selection: Binding(
                    get: { hermesVM.directProviderID },
                    set: { hermesVM.directProviderID = $0 })) {
                    ForEach(AIProviderRegistry.all, id: \.id) { provider in
                        Text(provider.displayName).tag(provider.id)
                    }
                }
            } label: {
                HermesRow("Provider", value: hermesVM.directProvider.displayName)
            }

            HermesDivider()

            Menu {
                Picker("Model", selection: Binding(
                    get: { hermesVM.directModel },
                    set: { hermesVM.directModel = $0 })) {
                    ForEach(hermesVM.directProvider.curatedModels, id: \.id) { model in
                        Text(model.label).tag(model.id)
                    }
                    // Allow a stored custom model to remain selectable
                    if !hermesVM.directProvider.curatedModels
                        .contains(where: { $0.id == hermesVM.directModel }) {
                        Text(hermesVM.directModel).tag(hermesVM.directModel)
                    }
                }
            } label: {
                HermesRow("Model", value: modelLabel)
            }

            if hermesVM.directProvider.allowsCustomBaseURL {
                HermesDivider()
                fieldRow(title: "Base URL") {
                    TextField("https://…", text: Binding(
                        get: { hermesVM.directBaseURL },
                        set: { hermesVM.directBaseURL = $0 }))
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .font(.system(size: 15, design: .monospaced))
                }
            }

            if hermesVM.directProvider.requiresKey {
                HermesDivider()
                fieldRow(title: "\(hermesVM.directProvider.displayName) API key") {
                    SecureField("sk-…", text: $providerKey)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .font(.system(size: 15, design: .monospaced))
                        .onSubmit {
                            hermesVM.setProviderKey(providerKey)
                            providerKey = ""
                        }
                }
                HermesDivider()
                HermesRow(
                    "Key status",
                    value: hermesVM.hasDirectKey ? "Saved in Keychain" : "Not set",
                    showsChevron: false
                )
            }
        }
    }

    private var modelLabel: String {
        hermesVM.directProvider.curatedModels
            .first { $0.id == hermesVM.directModel }?.label ?? hermesVM.directModel
    }

    // MARK: Bridge

    @ViewBuilder
    private var bridgeSection: some View {
        HermesSection(
            header: "Bridge connection",
            footer: "Bridge endpoint used in Bridge mode. Tap a preset to select it."
        ) {
            ForEach(hermesVM.endpointPresets, id: \.name) { preset in
                Button {
                    endpoint = preset.url
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.name)
                                .font(.system(size: 16))
                                .foregroundStyle(.primary)
                            Text(preset.url)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        if endpoint == preset.url {
                            Image(systemName: "checkmark")
                                .foregroundStyle(HermesTheme.accent)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Delete", role: .destructive) {
                        hermesVM.deletePreset(name: preset.name)
                        presetsVersion += 1
                    }
                }

                HermesDivider()
            }
            .id(presetsVersion)

            fieldRow(title: "WebSocket URL") {
                TextField("ws://…", text: $endpoint)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.system(size: 15, design: .monospaced))
            }

            HermesDivider()

            Button {
                presetName = ""
                showSavePreset = true
            } label: {
                Text("Save current URL as preset…")
                    .font(.system(size: 17))
                    .foregroundStyle(HermesTheme.accentOnCard)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(endpoint.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    /// Label over an editable field, inside a card row.
    private func fieldRow<Field: View>(
        title: String,
        @ViewBuilder field: () -> Field
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            field()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Voice & Microphone

private struct VoicePage: View {
    let hermesVM: HermesSessionViewModel
    /// The call-screen caveat is Ray-Ban Display only - glasses without a
    /// lens have nothing for the hands-free link to cover.
    let glassesHaveDisplay: Bool

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
                    // Not `MicSource.allCases`: the AiSee mic only exists
                    // when the AiSee glasses are the selected vendor.
                    ForEach(hermesVM.availableMicSources, id: \.self) { source in
                        Text(source.label(glassesHaveDisplay: glassesHaveDisplay))
                            .tag(source)
                    }
                }
                .pickerStyle(.inline)
            } header: {
                Text("Microphone")
            } footer: {
                Text(glassesHaveDisplay
                     ? "Glasses mode shows a CALL SCREEN on the lens and hides the HUD. Headset mode (AirPods etc.) is the pocket setup: talk and listen through the earbuds while the lens keeps the HUD. Audio never leaves your phone for speech-to-text."
                     : "Glasses mode uses the glasses' hands-free link for both mic and voice - call quality, so recognition can be a little less accurate. With the iPhone mic, Hermes still speaks through the glasses. Audio never leaves your phone for speech-to-text.")
            }

            Section {
                Toggle("iPhone voice", isOn: Binding(
                    get: { hermesVM.useDeviceTTS },
                    set: { hermesVM.useDeviceTTS = $0 }
                ))
            } header: {
                Text("Voice")
            } footer: {
                Text("On = faster but more robotic, generated on the phone. Off = natural voice generated on the bridge (adds 1–3 s per reply). Applies from the next question. Ignored while the ElevenLabs voice below is on.")
            }

            ElevenLabsVoiceSection()
        }
        .hermesFormStyle()
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
        .hermesFormStyle()
        .navigationTitle("Glasses Display")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Appearance

private struct AppearancePage: View {
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw =
        AppearanceMode.system.rawValue

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearanceRaw) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.label).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Force light or dark, or follow the phone's setting. Applies to the whole app.")
            }
        }
        .hermesFormStyle()
        .navigationTitle("Appearance")
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
                Toggle("Read name tags", isOn: Binding(
                    get: { hermesVM.badgeOCREnabled },
                    set: { hermesVM.badgeOCREnabled = $0 }
                ))
                .disabled(!hermesVM.socialNotesEnabled)
            } footer: {
                Text("While recording a conversation, Hermes reads any name badge it can see and labels that person on the timeline. Done entirely on this iPhone.")
            }

            Section {
                Toggle("Keep ID photos", isOn: Binding(
                    get: { hermesVM.badgePortraitsEnabled },
                    set: { hermesVM.badgePortraitsEnabled = $0 }
                ))
                .disabled(!hermesVM.socialNotesEnabled || !hermesVM.badgeOCREnabled)
            } footer: {
                Text("When someone's badge carries their photo, save that photo with the sighting. That saved copy stays on this iPhone and is never sent anywhere. Badge assist below is separate - when you turn it on, it sends a photo of the badge itself, and if the badge has a printed photo, that crop can include it.")
            }

            Section {
                Toggle("Ask AI to read hard badges", isOn: Binding(
                    get: { hermesVM.badgeAssistEnabled },
                    set: { hermesVM.badgeAssistEnabled = $0 }
                ))
                // Both badge toggles live UNDER "Remember people I meet":
                // with social notes off nothing can capture a sighting, so
                // offering their settings is offering settings for a
                // switched-off feature.
                .disabled(!hermesVM.socialNotesEnabled || !hermesVM.badgeOCREnabled)
            } footer: {
                Text(assistFooter)
            }

            Section {
                LabeledContent("Saved", value: "\(hermesVM.allEncounters().count)")
            } footer: {
                Text("Review, edit, and delete them on the People screen - the People quick action under the conversation.")
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
        .hermesFormStyle()
        .navigationTitle("People")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Says plainly what turning this on changes about where the photos go.
    private var assistFooter: String {
        guard hermesVM.socialNotesEnabled else {
            return "Turn on \"Remember people I meet\" first."
        }
        guard hermesVM.badgeOCREnabled else {
            return "Turn on \"Read name tags\" first."
        }
        guard hermesVM.hasDirectKey else {
            return "Add an API key under Brain to use this. After a recording ends, photos of people whose badge couldn't be read on-device would be sent to your AI provider - up to 6 per recording. Nothing is sent while you're recording."
        }
        return "After a recording ends, photos of people whose badge couldn't be read on-device are sent to your AI provider - up to 6 per recording. This is the only part of People that leaves your phone. Nothing is sent while you're recording."
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
                    Text("The lens shows text directions until a Mapbox token is added; the in-app map works either way. Get a free token at mapbox.com.")
                }
            }
        }
        .hermesFormStyle()
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
        .hermesFormStyle()
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
        .hermesFormStyle()
        .navigationTitle("What can I say?")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Developer (5d)

/// The subsystem test panel used to float over the session screen. It
/// lives here now, so nothing covers the conversation.
private struct DeveloperPage: View {
    let hermesVM: HermesSessionViewModel

    private static let tests = ["Bridge", "Sound", "Photo", "Query", "Visual", "Display"]

    /// Display is a Ray-Ban Display feature; AiSee has no lens.
    private var tests: [String] {
        var list = Self.tests.filter { $0 != "Display" || hermesVM.glassesSupportsDisplay }
        if hermesVM.glassesVendor == .aisee { list.insert("Mic", at: 1) }
        return list
    }

    var body: some View {
        HermesScrollPage {
            HermesNotice(
                text: "Test tools moved out of the session view. Everything that used to float over the chat is here.",
                systemImage: "info.circle"
            )

            HermesSection(header: "Test panel") {
                VStack(spacing: 10) {
                    LazyVGrid(
                        columns: Array(
                            repeating: GridItem(.flexible(), spacing: 8), count: 3
                        ),
                        spacing: 8
                    ) {
                        ForEach(tests, id: \.self) { name in
                            testButton(name)
                        }
                    }

                    // Failure from whichever test was just run - tracked
                    // explicitly, since `testResults` is a dictionary and
                    // scanning `.values` returns an arbitrary one, not
                    // necessarily the latest.
                    if let failure = hermesVM.lastTestFailure {
                        Text(failure)
                            .font(.caption2)
                            .foregroundStyle(HermesTheme.destructive)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineLimit(3)
                    }
                    if let photo = hermesVM.lastTestPhoto {
                        VStack(alignment: .leading, spacing: 6) {
                            Image(uiImage: photo)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 180)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            if let source = hermesVM.lastTestPhotoSource {
                                Text(source)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(16)
            }

            HermesSection(header: "Diagnostics") {
                HermesRow(title: "Mic level", showsChevron: false) {
                    HStack(spacing: 6) {
                        Image(systemName: "mic.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        ProgressView(value: min(1.0, Double(hermesVM.micLevel) * 8))
                            .frame(width: 90)
                    }
                }
                HermesDivider()
                HermesRow("Bridge", value: bridgeText, showsChevron: false)
                HermesDivider()
                HermesRow("Vision route", value: visionRouteText, showsChevron: false)
                HermesDivider()
                HermesRow("Audio output", value: hermesVM.lastTestAudioRoute ?? "Run the Sound test", showsChevron: false)
                if hermesVM.glassesVendor == .aisee {
                    HermesDivider()
                    HermesRow("AiSee mic", value: hermesVM.lastTestMicSummary ?? "Run the Mic test", showsChevron: false)
                    HermesDivider()
                    HermesRow("AiSee button", value: hermesVM.lastAiSeeKeyPress ?? "Press a key on the glasses", showsChevron: false)
                }
                if hermesVM.glassesVendor == .meta {
                    HermesDivider()
                    HermesRow("Glasses display", value: displayText, showsChevron: false)
                    HermesDivider()
                    HermesRow(
                        "Camera permission",
                        value: cameraText,
                        showsChevron: false
                    )
                }
            }
        }
        .navigationTitle("Developer")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func testButton(_ name: String) -> some View {
        Button {
            Task { await run(name) }
        } label: {
            HStack(spacing: 4) {
                if hermesVM.testRunning.contains(name) {
                    ProgressView().scaleEffect(0.6)
                } else if let result = hermesVM.testResults[name] ?? nil {
                    Image(systemName: result.isEmpty
                        ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.isEmpty
                            ? HermesTheme.online : HermesTheme.destructive)
                }
                Text(name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(HermesTheme.accentOnCard)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                HermesTheme.accent.opacity(0.1),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .disabled(hermesVM.testRunning.contains(name))
    }

    private func run(_ name: String) async {
        switch name {
        case "Bridge": await hermesVM.testBridge()
        case "Sound": await hermesVM.testSound()
        case "Mic": await hermesVM.testAiSeeMic()
        case "Photo": await hermesVM.testPhoto()
        case "Query": await hermesVM.testQuery()
        case "Visual": await hermesVM.testVisualQuery()
        case "Display": await hermesVM.testDisplay()
        default: break
        }
    }

    private var visionRouteText: String {
        switch hermesVM.visionRoute {
        case .glasses: return hermesVM.glassesVendor.cameraLabel
        case .phone: return "iPhone camera"
        }
    }

    private var bridgeText: String {
        switch hermesVM.bridgeStatus {
        case .reachable: return "Reachable"
        case .unreachable: return "Unreachable"
        case .checking: return "Checking…"
        case .unknown: return "Unknown"
        }
    }

    private var displayText: String {
        switch hermesVM.displayStatus {
        case .off: return "Off"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .unavailable: return "Unavailable"
        }
    }

    private var cameraText: String {
        switch hermesVM.cameraPermissionGranted {
        case .some(true): return "Granted"
        case .some(false): return "Denied"
        case .none: return "Unknown"
        }
    }
}

/// Settings -> Voice -> the natural voice. Owns no typed text (the key is
/// pasted from the clipboard in one tap), so nothing here can be lost to a
/// swipe-dismiss.
private struct ElevenLabsVoiceSection: View {
    @State private var enabled = ElevenLabsVoice.isEnabled
    @State private var keySource = ElevenLabsVoice.keySource
    @State private var voiceID = ElevenLabsVoice.voiceID
    @State private var note: String?

    var body: some View {
        Section {
            Toggle("ElevenLabs voice", isOn: $enabled)
                .onChange(of: enabled) { _, on in ElevenLabsVoice.isEnabled = on }
            LabeledContent("API key", value: keyLabel)
            Button("Paste key from clipboard") {
                let pasted = (UIPasteboard.general.string ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard pasted.count >= 20, !pasted.contains(" ") else {
                    note = "The clipboard doesn't hold an API key."
                    return
                }
                note = ElevenLabsVoice.storeKey(pasted) ? "Key saved." : "Couldn't save the key to the Keychain."
                keySource = ElevenLabsVoice.keySource
            }
            if keySource == .settings {
                Button("Remove key", role: .destructive) {
                    ElevenLabsVoice.storeKey("")
                    keySource = ElevenLabsVoice.keySource
                    note = keySource == .build ? "Removed. Using the key built into this app." : "Removed."
                }
            }
            TextField("Voice ID", text: $voiceID)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onChange(of: voiceID) { _, id in ElevenLabsVoice.voiceID = id }
            if let note {
                Text(note).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Natural voice")
        } footer: {
            Text("Replies are spoken by ElevenLabs, one sentence at a time, so speech starts while the answer is still being written. The reply text is sent to ElevenLabs. If it can't be reached, the iPhone voice takes over for that sentence. Leave Voice ID empty for the default voice.")
        }
    }

    private var keyLabel: String {
        switch keySource {
        case .settings: return "Saved on this iPhone"
        case .build: return "Built into this app"
        case .none: return "Not set - using the iPhone voice"
        }
    }
}
