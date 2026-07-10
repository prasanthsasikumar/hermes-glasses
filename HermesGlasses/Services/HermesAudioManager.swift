//
// HermesAudioManager.swift
//
// Manages audio capture from Meta Ray-Ban glasses and playback of
// Hermes Agent TTS responses. Uses AVAudioEngine for capture and playback.
//

import AVFoundation
import Foundation
import os

/// Manages audio capture and playback for the Hermes Glasses app
final class HermesAudioManager: NSObject, @unchecked Sendable {
    // MARK: - Callbacks

    var onAudioChunk: ((Data) -> Void)?
    var onSpeechDetected: (() -> Void)?
    var onSilenceDetected: (() -> Void)?
    var onPlaybackComplete: (() -> Void)?
    /// Diagnostic messages (mic route, levels) for remote debugging
    var onDebug: ((String) -> Void)?
    /// Raw tap buffer, pre-conversion — for on-device speech recognition
    var onRawBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// Mic RMS level (0..~1), throttled to ~4/s — for the UI level meter
    var onLevel: ((Float) -> Void)?

    // MARK: - Private

    private let logger = Logger(subsystem: "com.flowsxr.hermes-glasses", category: "audio")

    private let audioEngine = AVAudioEngine()
    private let inputNode: AVAudioNode
    private let outputNode: AVAudioNode
    private let captureFormat: AVAudioFormat

    private var isCapturing: Bool = false
    private var configChangeObserver: NSObjectProtocol?
    private var tapBufferCount: Int = 0
    private var lastDebugTime: TimeInterval = 0
    private var lastLevelTime: TimeInterval = 0

    // VAD
    private var isSpeechActive: Bool = false
    private var silenceCounter: Int = 0
    private let silenceThreshold: Float = 0.015
    private let silenceFrames: Int = 20
    private var vadDisabled: Bool = true

    // Playback
    private var playerNode: AVAudioPlayerNode?
    private var playbackBuffer: AVAudioPCMBuffer?

    override init() {
        inputNode = audioEngine.inputNode
        outputNode = audioEngine.outputNode

        // 16 kHz mono PCM16 — the format the bridge expects. This
        // initializer cannot fail for a standard PCM format.
        captureFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        super.init()
    }

    // MARK: - Public API

    var currentInputName: String {
        let session = AVAudioSession.sharedInstance()
        return session.currentRoute.inputs.first?.portName ?? "Unknown"
    }

    var isUsingBluetoothInput: Bool {
        AVAudioSession.sharedInstance().currentRoute.inputs.contains {
            $0.portType == .bluetoothHFP || $0.portType == .bluetoothA2DP
        }
    }

    /// Start capturing audio — uses iPhone mic by default (reliable).
    /// Set useGlassesMic=true to try routing through glasses Bluetooth.
    func startCapture(useGlassesMic: Bool = false) async throws {
        guard await requestMicrophonePermission() else {
            logger.error("Microphone permission denied")
            throw HermesAudioError.microphonePermissionDenied
        }

        let session = AVAudioSession.sharedInstance()

        if useGlassesMic {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetoothHFP]
            )

            if let btInput = session.availableInputs?.first(where: {
                $0.portType == .bluetoothHFP
            }) {
                try session.setPreferredInput(btInput)
            }

            try session.setActive(true)

            // Wait up to 3s for the Bluetooth route, without blocking the thread
            for _ in 0..<30 where !isUsingBluetoothInput {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        } else {
            // iPhone mic only: no Bluetooth options, so iOS cannot
            // re-route input to the glasses and kill the tap.
            // Mode .default, NOT .voiceChat: the voice-processing unit's
            // noise suppression gates speech down to the noise floor here.
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker]
            )
            try session.setActive(true)
        }

        logger.info("Audio session active. Input route: \(self.currentInputName, privacy: .public)")

        isCapturing = true
        tapBufferCount = 0
        observeConfigurationChanges()
        installTap()
        try audioEngine.start()
        logger.info("Audio engine started")
    }

    func stopCapture() {
        isCapturing = false
        // Stop playback but keep the node attached — it is reused across
        // sessions (attaching a second node would leak one per session)
        playerNode?.stop()
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    // MARK: - Playback

    func playResponse(_ audioData: Data) async {
        guard let buffer = audioDataToBuffer(audioData) else {
            logger.error("Could not build playback buffer (\(audioData.count) bytes)")
            onPlaybackComplete?()
            return
        }

        // One player, attached once and reused. Detaching a live node
        // raises NSException inside AVAudioEngine (SIGABRT on the second
        // response) — never detach, just stop/reschedule.
        let player: AVAudioPlayerNode
        if let existing = playerNode {
            player = existing
            player.stop()
        } else {
            player = AVAudioPlayerNode()
            audioEngine.attach(player)
            // TTS is always PCM16 mono 24kHz; the engine resamples to the
            // hardware rate through the mixer.
            audioEngine.connect(player, to: audioEngine.mainMixerNode, format: buffer.format)
            playerNode = player
        }

        if !audioEngine.isRunning {
            do {
                try audioEngine.start()
            } catch {
                logger.error("Engine start for playback failed: \(error.localizedDescription, privacy: .public)")
                onPlaybackComplete?()
                return
            }
        }

        logger.info("Playing TTS response: \(audioData.count) bytes")
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in
            Task { @MainActor [weak self] in
                self?.onPlaybackComplete?()
            }
        }

        player.play()
    }

    // MARK: - Private

    private func requestMicrophonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        @unknown default:
            return false
        }
    }

    /// A route change (e.g. iOS moving input to Bluetooth) stops the engine
    /// and invalidates the tap. Reinstall and restart so capture survives.
    private func observeConfigurationChanges() {
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isCapturing else { return }
            self.logger.info("Engine configuration changed — reinstalling tap. Route: \(self.currentInputName, privacy: .public)")
            self.inputNode.removeTap(onBus: 0)
            self.installTap()
            if !self.audioEngine.isRunning {
                do {
                    try self.audioEngine.start()
                } catch {
                    self.logger.error("Failed to restart engine: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func installTap() {
        let inputFormat = inputNode.outputFormat(forBus: 0)
        logger.info("Installing tap. Input format: \(inputFormat.sampleRate, privacy: .public) Hz, \(inputFormat.channelCount, privacy: .public) ch")

        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            logger.error("Input format is invalid (0 Hz) — no microphone available yet")
            return
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: captureFormat) else {
            logger.error("Failed to create AVAudioConverter")
            return
        }

        let session = AVAudioSession.sharedInstance()
        let inputs = session.currentRoute.inputs
            .map { "\($0.portName) (\($0.portType.rawValue))" }
            .joined(separator: ", ")
        sendDebug("tap installed: route=[\(inputs)] format=\(inputFormat.sampleRate)Hz/\(inputFormat.channelCount)ch gain=\(session.inputGain)")

        inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: inputFormat
        ) { [weak self] buffer, _ in
            self?.processInputBuffer(buffer, converter: converter)
        }
    }

    private func processInputBuffer(
        _ buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter
    ) {
        tapBufferCount += 1
        if tapBufferCount == 1 || tapBufferCount % 100 == 0 {
            logger.info("Tap delivered buffer #\(self.tapBufferCount, privacy: .public) (\(buffer.frameLength, privacy: .public) frames)")
        }

        onRawBuffer?(buffer)

        let nowLevel = Date().timeIntervalSince1970
        if nowLevel - lastLevelTime > 0.25, let onLevel {
            lastLevelTime = nowLevel
            let level = rawFloatRMS(buffer)
            DispatchQueue.main.async { onLevel(max(0, level)) }
        }

        let outputBuffer = convertBuffer(buffer, using: converter)
        guard let outputBuffer else { return }

        guard let channelData = outputBuffer.int16ChannelData else { return }
        let frameLength = Int(outputBuffer.frameLength)
        guard frameLength > 0 else { return }
        let data = Data(
            bytes: channelData[0],
            count: frameLength * MemoryLayout<Int16>.size
        )

        let rms = computeRMS(channelData[0], frameLength: frameLength)
        let isVoice = rms > silenceThreshold

        // Periodic level diagnostics: raw float level straight off the mic
        // vs. level after conversion, plus the active input route
        let now = Date().timeIntervalSince1970
        if now - lastDebugTime > 1.0 {
            lastDebugTime = now
            let raw = rawFloatRMS(buffer)
            let route = AVAudioSession.sharedInstance()
                .currentRoute.inputs.first?.portName ?? "none"
            sendDebug(String(
                format: "levels raw=%.4f converted=%.4f route=%@ frames=%d",
                raw, rms, route, buffer.frameLength
            ))
        }

        // Send audio whenever VAD is disabled or speech is in progress
        if vadDisabled || isVoice || isSpeechActive {
            DispatchQueue.main.async { [weak self] in
                self?.onAudioChunk?(data)
            }
        }

        // Always run the speech/silence state machine so end-of-utterance
        // is detected even when VAD gating is off.
        if isVoice {
            if !isSpeechActive {
                isSpeechActive = true
                DispatchQueue.main.async { [weak self] in
                    self?.onSpeechDetected?()
                }
            }
            silenceCounter = 0
        } else if isSpeechActive {
            silenceCounter += 1
            if silenceCounter >= silenceFrames {
                isSpeechActive = false
                silenceCounter = 0
                DispatchQueue.main.async { [weak self] in
                    self?.onSilenceDetected?()
                }
            }
        }
    }

    private func convertBuffer(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter
    ) -> AVAudioPCMBuffer? {
        let frameCapacity = AVAudioFrameCount(
            (Double(buffer.frameLength)
            * (captureFormat.sampleRate / buffer.format.sampleRate))
            .rounded(.up)
        )

        guard frameCapacity > 0, let output = AVAudioPCMBuffer(
            pcmFormat: captureFormat,
            frameCapacity: frameCapacity
        ) else { return nil }

        // Hand the input buffer to the converter exactly once per call;
        // returning it repeatedly makes the converter re-consume stale data.
        var consumed = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        var error: NSError?
        converter.convert(to: output, error: &error, withInputFrom: inputBlock)
        return error == nil ? output : nil
    }

    private func sendDebug(_ message: String) {
        logger.info("\(message, privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            self?.onDebug?(message)
        }
    }

    /// RMS of the untouched float buffer straight from the input tap
    private func rawFloatRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else {
            return -1
        }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n {
            let s = channels[0][i]
            sum += s * s
        }
        return sqrt(sum / Float(n))
    }

    private func computeRMS(_ samples: UnsafePointer<Int16>, frameLength: Int) -> Float {
        var sum: Float = 0
        for i in 0..<frameLength {
            let sample = Float(samples[i]) / 32768.0
            sum += sample * sample
        }
        return sqrt(sum / Float(frameLength))
    }

    /// Build a Float32 buffer from raw PCM16 mono 24kHz data.
    /// AVAudioPlayerNode only accepts Float32 buffers — scheduling an
    /// Int16 buffer raises an exception and crashes.
    private func audioDataToBuffer(_ data: Data) -> AVAudioPCMBuffer? {
        let sampleRate: Double = 24000
        let frameCount = AVAudioFrameCount(data.count / 2)
        guard frameCount > 0 else { return nil }

        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ) else { return nil }

        buffer.frameLength = frameCount
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            guard let dst = buffer.floatChannelData?[0] else { return }
            for i in 0..<Int(frameCount) {
                dst[i] = Float(src[i]) / 32768.0
            }
        }

        return buffer
    }
}

enum HermesAudioError: LocalizedError {
    case converterFailed
    case microphonePermissionDenied

    var errorDescription: String? {
        switch self {
        case .converterFailed:
            return "Audio converter could not be created."
        case .microphonePermissionDenied:
            return "Microphone access denied. Enable it in Settings → Privacy & Security → Microphone → Hermes Glasses."
        }
    }
}
