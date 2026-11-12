//
// HermesGlassesApp.swift
// Hermes Glasses - Talk to Hermes AI from Meta Ray-Ban glasses
//
// Main entry point. Configures the Meta Wearables DAT SDK, sets up
// audio capture from the glasses, and connects to Hermes Agent for
// real-time voice conversation.
//

import MWDATCore
import SwiftUI
import os

#if DEBUG
import MWDATMockDevice
#endif

private let logger = Logger(subsystem: "com.flowsxr.hermesglasses", category: "startup")

@main
struct HermesGlassesApp: App {
    @State private var wearablesViewModel: WearablesViewModel
    @State private var hermesSessionViewModel: HermesSessionViewModel
    @State private var buildCheckViewModel: BuildCheckViewModel
    @State private var machineGuideViewModel: MachineGuideViewModel
    @State private var permissions = PermissionsCoordinator()

    /// First launch runs the three-step wizard (glasses → permissions →
    /// ready) so nobody meets a bare system dialog with no explanation.
    @AppStorage("onboarding_complete") private var onboardingComplete = false

    // Light/dark override, applied to the whole window (see AppearanceMode).
    @AppStorage(AppearanceMode.storageKey) private var appearanceRaw =
        AppearanceMode.system.rawValue
    private var appearance: AppearanceMode {
        AppearanceMode(rawValue: appearanceRaw) ?? .system
    }

    init() {
        // Step 1: Configure the DAT SDK once at launch
        do {
            try Wearables.configure()
        } catch {
            // Unconditional: a release build with a broken SDK config should
            // still leave a breadcrumb, not just the DEBUG console.
            logger.error("Failed to configure Wearables SDK: \(error.localizedDescription, privacy: .public)")
        }

        #if DEBUG
        // Enable MockDeviceKit for testing without physical glasses
        if ProcessInfo.processInfo.arguments.contains("--mock-device") {
            MockDeviceKit.shared.enable(
                config: MockDeviceKitConfig(initiallyRegistered: false)
            )
        }
        #endif

        let wearables = Wearables.shared
        self._wearablesViewModel = State(
            wrappedValue: WearablesViewModel(wearables: wearables)
        )
        let session = HermesSessionViewModel(wearables: wearables)
        self._hermesSessionViewModel = State(wrappedValue: session)
        self._buildCheckViewModel = State(wrappedValue: BuildCheckViewModel(hermesVM: session))
        self._machineGuideViewModel = State(wrappedValue: MachineGuideViewModel(hermesVM: session))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                ContentView(
                    wearablesVM: wearablesViewModel,
                    hermesVM: hermesSessionViewModel,
                    buildCheckVM: buildCheckViewModel,
                    machineGuideVM: machineGuideViewModel
                )
                // Handle Meta AI URL callback after registration
                .onOpenURL { url in
                    Task {
                        _ = try? await Wearables.shared.handleUrl(url)
                    }
                }
                .alert("Hermes Error", isPresented: $hermesSessionViewModel.showError) {
                    Button("OK") { hermesSessionViewModel.dismissError() }
                } message: {
                    Text(hermesSessionViewModel.errorMessage)
                }
                // Separate surface, deliberately not titled as a fault: a
                // fallback that worked ("using the iPhone mic") is news, not
                // an error, and the Error alert said otherwise.
                .alert("Hermes", isPresented: $hermesSessionViewModel.showNotice) {
                    Button("OK") { hermesSessionViewModel.dismissNotice() }
                } message: {
                    Text(hermesSessionViewModel.noticeMessage)
                }
            }
            // A cover, not a sibling: as a sibling it laid out UNDER the
            // session screen, leaving half the app visible above it.
            //
            // Gated on `onboardingComplete`: onboarding's own glasses step
            // can also drive `registrationState` to `.registering` (its
            // "Connect Glasses" button), and it already shows its own
            // inline waiting state (OnboardingView.swift:75-82) for exactly
            // that. Without the gate, two full-screen covers wanted to
            // present at once.
            .fullScreenCover(isPresented: Binding(
                get: {
                    onboardingComplete
                        && wearablesViewModel.registrationState == .registering
                },
                set: { _ in }
            )) {
                RegistrationInProgressView(viewModel: wearablesViewModel)
            }
            // Force light/dark for the whole window (sheets included).
            .preferredColorScheme(appearance.colorScheme)
            .fullScreenCover(isPresented: Binding(
                get: { !onboardingComplete },
                set: { onboardingComplete = !$0 }
            )) {
                OnboardingView(
                    wearablesVM: wearablesViewModel,
                    hermesVM: hermesSessionViewModel,
                    permissions: permissions
                ) { startSession in
                    onboardingComplete = true
                    if startSession {
                        Task { await hermesSessionViewModel.startSession() }
                    }
                }
            }
        }
    }
}
