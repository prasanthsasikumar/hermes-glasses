//
// HermesSessionViewModel.swift
//
// Core view model managing the Hermes voice conversation session.
// Connects to Meta glasses, captures audio, streams to Hermes Agent,
// and plays back responses through the glasses.
//

import MWDATCore
import Observation
import os
import SwiftUI

/// Represents the current state of the Hermes conversation
enum HermesConnectionState: Equatable {
    case disconnected
    case connecting
    case listening
    case recording
    case processing
    case speaking
    case error(String)
}

@Observable
@MainActor
final class HermesSessionViewModel {
    // MARK: - Published state

    var connectionState: HermesConnectionState = .disconnected
    var isGlassesConnected: Bool = false
    var lastTranscript: String = ""
    var lastResponse: String = ""
    var conversationHistory: [ConversationTurn] = []
    var showError: Bool = false
    var errorMessage: String = ""

    /// Hermes Agent WebSocket endpoint
    var hermesEndpoint: String {
        UserDefaults.standard.string(forKey: "hermes_endpoint")
            ?? "ws://localhost:8765/voice"
    }

    // MARK: - Private

    @ObservationIgnored private let wearables: WearablesInterface
    @ObservationIgnored private var deviceSelector: AutoDeviceSelector
    @ObservationIgnored private var deviceSession: DeviceSession?
    @ObservationIgnored private let audioManager = HermesAudioManager()
    @ObservationIgnored private var apiClient: HermesAPIClient?
    @ObservationIgnored private var sessionObserverTask: Task<Void, Never>?
    @ObservationIgnored private let cameraManager = HermesCameraManager()
    @ObservationIgnored private var pendingPhoto: Data?

    /// Exposed for UI to show audio route
    var audio: HermesAudioManager { audioManager }

    init(wearables: WearablesInterface) {
        self.wearables = wearables
        self.deviceSelector = AutoDeviceSelector(wearables: wearables)
    }

    deinit {
        sessionObserverTask?.cancel()
    }

    // MARK: - Public API

    func startSession() async {
        connectionState = .connecting

        // 1. Create and start a device session with the glasses
        let session: DeviceSession
        do {
            session = try wearables.createSession(deviceSelector: deviceSelector)
        } catch {
            show("Failed to create session: \(error.localizedDescription)")
            connectionState = .disconnected
            return
        }
        deviceSession = session

        // Single state observer — use a continuation to signal readiness
        do {
            // Boxed flag so both the Task and outer scope can access it
            let done = OSAllocatedUnfairLock(initialState: false)

            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let stateStream = session.stateStream()
                let errorStream = session.errorStream()

                sessionObserverTask = Task { [weak self] in
                    await withTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for await state in stateStream {
                                if Task.isCancelled { return }
                                switch state {
                                case .started:
                                    done.withLock { finished in
                                        if !finished {
                                            finished = true
                                            cont.resume()
                                        }
                                    }
                                    await self?.handleSessionState(state)
                                case .stopped, .stopping:
                                    done.withLock { finished in
                                        if !finished {
                                            finished = true
                                            cont.resume(
                                                throwing: DeviceSessionError.unexpectedError(
                                                    description: "Session stopped unexpectedly"
                                                )
                                            )
                                            return
                                        }
                                    }
                                    await self?.handleSessionState(state)
                                    return
                                case .paused:
                                    await self?.handleSessionState(state)
                                case .starting, .idle:
                                    break
                                @unknown default:
                                    break
                                }
                            }
                        }
                        group.addTask {
                            for await error in errorStream {
                                if Task.isCancelled { return }
                                done.withLock { finished in
                                    if !finished {
                                        finished = true
                                        cont.resume(throwing: error)
                                        return
                                    }
                                }
                                await self?.handleSessionError(error)
                                return
                            }
                        }
                    }
                }

                // Now start the session
                do {
                    try session.start()
                } catch {
                    done.withLock { finished in
                        if !finished {
                            finished = true
                            cont.resume(throwing: error)
                        }
                    }
                    return
                }

                // Check if already started (race: started before streams iterate)
                done.withLock { finished in
                    if !finished && session.state == .started {
                        finished = true
                        cont.resume()
                    }
                }
            }
        } catch DeviceSessionError.datAppOnTheGlassesUpdateRequired {
            show("Glasses app needs update. Please update in Meta AI app.")
            connectionState = .disconnected
            return
        } catch {
            show("Failed to connect glasses: \(error.localizedDescription)")
            connectionState = .disconnected
            return
        }

        // Session is started — set up Hermes and audio
        isGlassesConnected = true
        cameraManager.configure(session: session)

        // 2. Connect to Hermes first, with all callbacks wired up before
        // any audio flows, so no chunks are dropped.
        let client = HermesAPIClient(endpoint: hermesEndpoint)
        apiClient = client

        client.onTranscript = { [weak self] text in
            Task { @MainActor [weak self] in
                self?.lastTranscript = text
                self?.connectionState = .processing
            }
        }
        client.onResponse = { [weak self] text in
            Task { @MainActor [weak self] in
                self?.lastResponse = text
                self?.addTurn(
                    userText: self?.lastTranscript ?? "",
                    agentText: text
                )
            }
        }
        client.onAudioResponse = { [weak self] audioData in
            Task { @MainActor [weak self] in
                self?.connectionState = .speaking
                await self?.audioManager.playResponse(audioData)
            }
        }
        // Fires only when the bridge sent no TTS audio at all
        client.onPlaybackComplete = { [weak self] in
            Task { @MainActor [weak self] in
                self?.connectionState = .listening
            }
        }
        client.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.show(error)
            }
        }
        client.onCapturePhotoRequested = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let photo = try await self.cameraManager.capturePhoto()
                    self.pendingPhoto = photo
                    self.apiClient?.sendPhoto(photo)
                } catch {
                    self.apiClient?.sendPhotoError(error.localizedDescription)
                }
            }
        }

        let connected = await client.connect()
        guard connected else {
            show("Failed to connect to Hermes bridge at \(hermesEndpoint)")
            endSession()
            return
        }

        // 3. Start audio capture (iPhone mic first; glasses routing later)
        audioManager.onAudioChunk = { [weak self] chunk in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Don't stream the mic while Hermes is thinking or talking —
                // without echo cancellation the mic hears the TTS and the
                // bridge would transcribe Hermes back to itself.
                switch self.connectionState {
                case .processing, .speaking:
                    return
                default:
                    self.apiClient?.sendAudioChunk(chunk)
                }
            }
        }
        audioManager.onPlaybackComplete = { [weak self] in
            Task { @MainActor [weak self] in
                if case .speaking = self?.connectionState {
                    self?.connectionState = .listening
                }
            }
        }
        audioManager.onDebug = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.apiClient?.sendDebug(message)
            }
        }
        audioManager.onSpeechDetected = { [weak self] in
            Task { @MainActor [weak self] in
                self?.connectionState = .recording
            }
        }
        audioManager.onSilenceDetected = { [weak self] in
            Task { @MainActor [weak self] in
                if case .recording = self?.connectionState {
                    self?.connectionState = .processing
                    await self?.apiClient?.finalizeAudio()
                }
            }
        }

        do {
            try await audioManager.startCapture()
        } catch {
            show("Audio setup failed: \(error.localizedDescription)")
            endSession()
            return
        }

        // Bridge connected and mic capturing — ready to listen
        connectionState = .listening
    }

    func endSession() {
        sessionObserverTask?.cancel()
        sessionObserverTask = nil
        audioManager.stopCapture()
        apiClient?.disconnect()
        apiClient = nil
        cameraManager.reset()
        deviceSession?.stop()
        deviceSession = nil
        isGlassesConnected = false
        connectionState = .disconnected
    }

    func setEndpoint(_ endpoint: String) {
        UserDefaults.standard.set(endpoint, forKey: "hermes_endpoint")
    }

    func dismissError() {
        showError = false
    }

    // MARK: - Private

    private func handleSessionState(_ state: DeviceSessionState) async {
        switch state {
        case .started:
            isGlassesConnected = true
        case .stopped, .stopping:
            endSession()
        case .paused:
            connectionState = .disconnected
        case .starting, .idle:
            break
        @unknown default:
            break
        }
    }

    private func handleSessionError(_ error: DeviceSessionError) async {
        show(error.localizedDescription)
    }

    private func addTurn(userText: String, agentText: String) {
        let turn = ConversationTurn(
            userText: userText,
            agentText: agentText,
            timestamp: Date(),
            photo: pendingPhoto
        )
        pendingPhoto = nil
        conversationHistory.append(turn)
        if conversationHistory.count > 50 {
            conversationHistory.removeFirst()
        }
        lastTranscript = ""
    }

    private func show(_ message: String) {
        errorMessage = message
        showError = true
    }
}

struct ConversationTurn: Identifiable {
    let id = UUID()
    let userText: String
    let agentText: String
    let timestamp: Date
    var photo: Data? = nil
}
