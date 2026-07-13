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

#if DEBUG
import MWDATMockDevice
#endif

@main
struct HermesGlassesApp: App {
    @State private var wearablesViewModel: WearablesViewModel
    @State private var hermesSessionViewModel: HermesSessionViewModel

    init() {
        // Step 1: Configure the DAT SDK once at launch
        do {
            try Wearables.configure()
        } catch {
            #if DEBUG
            NSLog("[HermesGlasses] Failed to configure Wearables SDK: \(error)")
            #endif
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
        self._hermesSessionViewModel = State(
            wrappedValue: HermesSessionViewModel(wearables: wearables)
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                wearablesVM: wearablesViewModel,
                hermesVM: hermesSessionViewModel
            )
            // Handle Meta AI URL callback after registration
            .onOpenURL { url in
                Task {
                    _ = try? await Wearables.shared.handleUrl(url)
                }
            }
            // Error alerts
            .alert("Error", isPresented: $wearablesViewModel.showError) {
                Button("OK") { wearablesViewModel.dismissError() }
            } message: {
                Text(wearablesViewModel.errorMessage)
            }
            .alert("Hermes Error", isPresented: $hermesSessionViewModel.showError) {
                Button("OK") { hermesSessionViewModel.dismissError() }
            } message: {
                Text(hermesSessionViewModel.errorMessage)
            }

            // Registration overlay
            RegistrationView(viewModel: wearablesViewModel)
        }
    }
}
