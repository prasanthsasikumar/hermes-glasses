//
// WearablesViewModel.swift
//
// Manages Meta Wearables DAT SDK registration and device lifecycle.
// Adapted from the CameraAccess sample app patterns.
//

import MWDATCore
import Observation
import SwiftUI

/// Registration states for the Meta AI companion app integration
enum AppRegistrationState {
    case notRegistered
    case registering
    case registered
    case unavailable
}

@Observable
@MainActor
final class WearablesViewModel {
    var devices: [DeviceIdentifier] = []
    var registrationState: AppRegistrationState = .notRegistered
    var showError: Bool = false
    var errorMessage: String = ""
    var requiresFirmwareUpdate: Bool = false

    @ObservationIgnored private let wearables: WearablesInterface
    @ObservationIgnored private var registrationTask: Task<Void, Never>?
    @ObservationIgnored private var deviceStreamTask: Task<Void, Never>?
    @ObservationIgnored private var deviceCompatibility: [DeviceIdentifier: Compatibility] = [:]
    @ObservationIgnored private var compatibilityTokens: [DeviceIdentifier: AnyListenerToken] = [:]

    init(wearables: WearablesInterface) {
        self.wearables = wearables
        self.devices = wearables.devices
        self.registrationState = mapState(wearables.registrationState)

        // Observe registration state changes
        registrationTask = Task { [weak self] in
            for await state in wearables.registrationStateStream() {
                guard let self, !Task.isCancelled else { return }
                self.registrationState = self.mapState(state)
            }
        }

        // Observe device availability
        deviceStreamTask = Task { [weak self] in
            for await devices in wearables.devicesStream() {
                guard let self, !Task.isCancelled else { return }
                self.devices = devices
                self.monitorCompatibility(devices: devices)
            }
        }
    }

    deinit {
        registrationTask?.cancel()
        deviceStreamTask?.cancel()
    }

    // MARK: - Public API

    func connectGlasses() {
        guard registrationState != .registering else { return }
        Task { @MainActor in
            do {
                try await wearables.startRegistration()
            } catch let error as RegistrationError {
                show(error.description)
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    func disconnectGlasses() {
        Task { @MainActor in
            do {
                try await wearables.startUnregistration()
            } catch let error as UnregistrationError {
                show(error.description)
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    func openFirmwareUpdate() {
        Task {
            do {
                try await wearables.openFirmwareUpdate()
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    func dismissError() {
        showError = false
    }

    // MARK: - Private

    private func mapState(_ state: RegistrationState) -> AppRegistrationState {
        switch state {
        case .registered: return .registered
        case .registering: return .registering
        case .available: return .notRegistered
        case .unavailable: return .unavailable
        @unknown default: return .unavailable
        }
    }

    private func show(_ message: String) {
        errorMessage = message
        showError = true
    }

    private func monitorCompatibility(devices: [DeviceIdentifier]) {
        let deviceSet = Set(devices)
        compatibilityTokens = compatibilityTokens.filter { deviceSet.contains($0.key) }
        deviceCompatibility = deviceCompatibility.filter { deviceSet.contains($0.key) }
        updateFirmwareRequired()

        for deviceId in devices {
            guard compatibilityTokens[deviceId] == nil else { continue }
            guard let device = wearables.deviceForIdentifier(deviceId) else { continue }
            deviceCompatibility[deviceId] = device.compatibility()
            updateFirmwareRequired()

            let token = device.addCompatibilityListener { [weak self] compat in
                Task { @MainActor [weak self] in
                    self?.deviceCompatibility[deviceId] = compat
                    self?.updateFirmwareRequired()
                }
            }
            compatibilityTokens[deviceId] = token
        }
    }

    private func updateFirmwareRequired() {
        requiresFirmwareUpdate = deviceCompatibility.values.contains(.deviceUpdateRequired)
    }
}
