//
// HermesAPIClient.swift
//
// WebSocket client for communicating with Hermes Agent's voice endpoint.
// Handles bidirectional audio streaming: sends captured audio from glasses,
// receives STT transcripts, agent text responses, and TTS audio.
//

import Foundation

/// WebSocket-based client for Hermes Agent voice API
final class HermesAPIClient: NSObject {
    // MARK: - Callbacks

    var onTranscript: ((String) -> Void)?
    var onResponse: ((String) -> Void)?
    var onAudioResponse: ((Data) -> Void)?
    var onPlaybackComplete: (() -> Void)?
    var onError: ((String) -> Void)?
    /// Called when the WebSocket disconnects
    var onDisconnected: (() -> Void)?
    /// Bridge asks the app to take a photo with the glasses
    var onCapturePhotoRequested: (() -> Void)?
    /// Bridge confirmed the conversation was reset
    var onSessionReset: (() -> Void)?

    // MARK: - Private

    private let endpoint: String
    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private(set) var isConnected: Bool = false
    private var receiveTask: Task<Void, Never>?
    private var isFinalized: Bool = false
    /// TTS audio accumulated between audio_start and audio_end
    private var ttsBuffer = Data()

    init(endpoint: String) {
        self.endpoint = endpoint
        super.init()
    }

    // MARK: - Public API

    /// Connect to the Hermes bridge and wait for its welcome message.
    /// Returns true once the bridge has confirmed the connection.
    @discardableResult
    func connect() async -> Bool {
        guard let url = URL(string: endpoint) else {
            await reportError("Invalid Hermes endpoint URL: \(endpoint)")
            return false
        }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        let urlSession = URLSession(configuration: config)
        session = urlSession

        let ws = urlSession.webSocketTask(with: url)
        webSocket = ws
        ws.resume()

        do {
            // The bridge sends {"type":"welcome"} immediately on connect
            let first = try await ws.receive()
            isConnected = true
            await handleMessage(first)

            receiveTask = Task { [weak self] in
                await self?.receiveLoop()
            }
            return true
        } catch {
            await reportError("Failed to connect to Hermes: \(error.localizedDescription)")
            disconnect()
            return false
        }
    }

    /// Disconnect from Hermes
    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        webSocket?.cancel(with: .normalClosure, reason: nil)
        webSocket = nil
        session?.invalidateAndCancel()
        session = nil
        isConnected = false
        isFinalized = false
        Task { @MainActor in
            onDisconnected?()
        }
    }

    func sendAudioChunk(_ data: Data) {
        guard isConnected, let ws = webSocket, !isFinalized else { return }

        ws.send(.data(data)) { [weak self] error in
            if let error {
                Task { @MainActor in
                    self?.onError?("Send error: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Send a diagnostic message that the bridge prints to its log
    func sendDebug(_ message: String) {
        guard isConnected, let ws = webSocket else { return }
        let payload: [String: String] = ["type": "debug", "msg": message]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        ws.send(.string(text)) { _ in }
    }

    /// Ask the bridge to forget the conversation (same-day memory reset)
    func sendNewSession() {
        guard isConnected, let ws = webSocket else { return }
        ws.send(.string(#"{"type":"new_session"}"#)) { _ in }
    }

    /// Send an on-device-transcribed query; the bridge skips STT for these
    func sendQuery(_ text: String) {
        guard isConnected, let ws = webSocket else { return }
        let payload: [String: String] = ["type": "query", "text": text]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        ws.send(.string(json)) { [weak self] error in
            if let error {
                Task { @MainActor in
                    self?.onError?("Query send error: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Send a captured JPEG as base64 JSON (binary frames are mic audio only)
    func sendPhoto(_ data: Data) {
        guard isConnected, let ws = webSocket else { return }
        let payload: [String: String] = [
            "type": "photo",
            "data": data.base64EncodedString(),
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: json, encoding: .utf8) else { return }
        ws.send(.string(text)) { [weak self] error in
            if let error {
                Task { @MainActor in
                    self?.onError?("Photo send error: \(error.localizedDescription)")
                }
            }
        }
    }

    func sendPhotoError(_ message: String) {
        guard isConnected, let ws = webSocket else { return }
        let payload: [String: String] = ["type": "photo_error", "message": message]
        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: json, encoding: .utf8) else { return }
        ws.send(.string(text)) { _ in }
    }

    func finalizeAudio() async {
        guard isConnected, let ws = webSocket, !isFinalized else { return }
        isFinalized = true

        let endMarker = #"{"type":"end_of_audio"}"#
        ws.send(.string(endMarker)) { [weak self] error in
            if let error {
                Task { @MainActor in
                    self?.onError?("Finalize error: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Private

    private func receiveLoop() async {
        guard let ws = webSocket else { return }

        while !Task.isCancelled, ws.closeCode == .invalid {
            do {
                let message = try await ws.receive()
                await handleMessage(message)
            } catch {
                isConnected = false
                if !Task.isCancelled {
                    await reportError("Connection lost: \(error.localizedDescription)")
                    await MainActor.run { [weak self] in
                        self?.onDisconnected?()
                    }
                }
                break
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) async {
        switch message {
        case .string(let text):
            await handleTextMessage(text)
        case .data(let data):
            // Binary from the bridge is a TTS chunk; play only when complete
            ttsBuffer.append(data)
        @unknown default:
            break
        }
    }

    private func handleTextMessage(_ text: String) async {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        await MainActor.run { [weak self] in
            switch type {
            case "welcome":
                break
            case "transcript":
                if let transcript = json["text"] as? String {
                    self?.onTranscript?(transcript)
                }
            case "response":
                if let response = json["text"] as? String {
                    self?.onResponse?(response)
                }
            case "audio_start":
                self?.ttsBuffer.removeAll()
            case "audio_end":
                if let self, !self.ttsBuffer.isEmpty {
                    let audio = self.ttsBuffer
                    self.ttsBuffer.removeAll()
                    self.onAudioResponse?(audio)
                } else {
                    self?.onPlaybackComplete?()
                }
                self?.isFinalized = false
            case "error":
                if let msg = json["message"] as? String {
                    self?.onError?("Hermes: \(msg)")
                }
            case "capture_photo":
                self?.onCapturePhotoRequested?()
            case "session_reset":
                self?.onSessionReset?()
            default:
                break
            }
        }
    }

    private func reportError(_ message: String) async {
        await MainActor.run { [weak self] in
            self?.onError?(message)
        }
    }
}
