//
// HermesSpeechRecognizer.swift
//
// On-device live speech recognition. Feeds mic buffers to Apple's Speech
// framework and reports partial transcripts word-by-word; an utterance is
// finalized after a short pause (or on demand via finalizeNow()), then the
// recognizer restarts for the next utterance.
//

import AVFoundation
import Foundation
import os
import Speech

enum HermesSpeechError: LocalizedError {
    case notAuthorized
    case recognizerUnavailable

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Speech recognition access denied. Enable it in Settings → Privacy & Security → Speech Recognition."
        case .recognizerUnavailable:
            return "Speech recognition is not available on this device."
        }
    }
}

final class HermesSpeechRecognizer: NSObject, @unchecked Sendable {
    // MARK: - Callbacks (delivered on the main queue)

    /// Live partial transcript — fires as words are recognized
    var onPartial: ((String) -> Void)?
    /// Utterance complete (pause or finalizeNow) — trimmed, never empty
    var onFinal: ((String) -> Void)?

    // MARK: - Private

    private let logger = Logger(subsystem: "com.flowsxr.hermes-glasses", category: "speech")
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latestPartial: String = ""
    private var lastChangeAt: Date = .distantPast
    private var pauseWatchdog: Task<Void, Never>?
    private var isRunning = false
    /// When true, incoming buffers are dropped (e.g. while TTS plays)
    var isSuspended = false

    /// Silence after the last new word before the utterance is final
    private let pauseInterval: TimeInterval = 1.5

    // MARK: - Public API

    func requestAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { status in
                    cont.resume(returning: status == .authorized)
                }
            }
        @unknown default:
            return false
        }
    }

    func start() throws {
        guard let recognizer, recognizer.isAvailable else {
            throw HermesSpeechError.recognizerUnavailable
        }
        guard !isRunning else { return }
        isRunning = true
        startRecognitionCycle()
        startPauseWatchdog()
        logger.info("Speech recognition started (onDevice=\(recognizer.supportsOnDeviceRecognition))")
    }

    func stop() {
        isRunning = false
        pauseWatchdog?.cancel()
        pauseWatchdog = nil
        tearDownCycle()
    }

    /// Feed a raw mic buffer (any format — Speech converts internally)
    func append(_ buffer: AVAudioPCMBuffer) {
        guard isRunning, !isSuspended else { return }
        request?.append(buffer)
    }

    /// Force the current partial to be treated as final immediately
    func finalizeNow() {
        emitFinalIfAny()
    }

    // MARK: - Private

    private func startRecognitionCycle() {
        guard let recognizer else { return }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        request = req
        latestPartial = ""
        lastChangeAt = .distantPast

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self, self.isRunning else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                if text != self.latestPartial {
                    self.latestPartial = text
                    self.lastChangeAt = Date()
                    DispatchQueue.main.async { [weak self] in
                        self?.onPartial?(text)
                    }
                }
                if result.isFinal {
                    self.emitFinalIfAny()
                }
            }

            if error != nil {
                // Recognizer gave up (silence limit, cancellation, transient
                // failure). Emit anything we have and start a fresh cycle.
                self.emitFinalIfAny()
                if self.isRunning {
                    self.tearDownCycle()
                    self.startRecognitionCycle()
                }
            }
        }
    }

    private func tearDownCycle() {
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
    }

    private func startPauseWatchdog() {
        pauseWatchdog?.cancel()
        pauseWatchdog = Task { [weak self] in
            while let self, !Task.isCancelled, self.isRunning {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if self.isSuspended { continue }
                let idle = Date().timeIntervalSince(self.lastChangeAt)
                if !self.latestPartial.isEmpty, idle >= self.pauseInterval {
                    self.emitFinalIfAny()
                }
            }
        }
    }

    private func emitFinalIfAny() {
        let text = latestPartial.trimmingCharacters(in: .whitespacesAndNewlines)
        latestPartial = ""
        lastChangeAt = .distantPast

        // Restart the cycle so the next utterance starts clean
        if isRunning {
            tearDownCycle()
            startRecognitionCycle()
        }

        guard !text.isEmpty else { return }
        logger.info("Utterance final: \(text, privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            self?.onFinal?(text)
        }
    }
}
