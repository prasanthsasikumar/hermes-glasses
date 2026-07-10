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
    /// Incremented on every cycle start; callbacks from cancelled tasks
    /// carry an older generation and are ignored. Without this, each
    /// task.cancel() fires that task's handler with an error, which would
    /// tear down the NEW cycle — cascading until the recognizer is deaf
    /// while the UI still says Listening.
    private var cycleGeneration = 0
    private var latestPartial: String = ""
    private var lastChangeAt: Date = .distantPast
    private var pauseWatchdog: Task<Void, Never>?
    private var isRunning = false
    /// When true, no recognition runs (e.g. while TTS plays). Suspending
    /// discards any half-heard words and tears the cycle down entirely;
    /// unsuspending starts a fresh cycle. This way TTS can't leak into the
    /// next query and no task churns on silence while suspended.
    var isSuspended = false {
        didSet {
            guard isSuspended != oldValue else { return }
            latestPartial = ""
            lastChangeAt = .distantPast
            if isSuspended {
                if isRunning { tearDownCycle() }
                DispatchQueue.main.async { [weak self] in
                    self?.onPartial?("")
                }
            } else {
                if isRunning { startRecognitionCycle() }
            }
        }
    }

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

    /// Restart the recognition cycle with a fresh request. Required after
    /// an audio route change: the tap's buffer format changes and
    /// SFSpeechAudioBufferRecognitionRequest cannot absorb that mid-request.
    func restartCycle() {
        guard isRunning else { return }
        latestPartial = ""
        lastChangeAt = .distantPast
        tearDownCycle()
        if !isSuspended {
            startRecognitionCycle()
        }
    }

    // MARK: - Private

    private func startRecognitionCycle() {
        guard let recognizer, !isSuspended else { return }

        cycleGeneration += 1
        let generation = cycleGeneration

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        request = req
        latestPartial = ""
        lastChangeAt = .distantPast

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self, self.isRunning,
                  generation == self.cycleGeneration else { return }

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
                // Recognizer gave up (silence limit, transient failure).
                // Emit anything we have and start a fresh cycle.
                self.logger.info("Recognition cycle #\(generation) ended with error — restarting")
                self.emitFinalIfAny()
            }
        }
    }

    private func tearDownCycle() {
        // Invalidate in-flight callbacks BEFORE cancel — cancel fires the
        // old task's handler with an error, which must see itself as stale
        cycleGeneration += 1
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

        // Restart the cycle so the next utterance starts clean (skipped
        // while suspended — unsuspend starts the next cycle)
        if isRunning, !isSuspended {
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
