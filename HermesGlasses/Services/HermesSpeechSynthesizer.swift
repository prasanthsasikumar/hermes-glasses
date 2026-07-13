//
// HermesSpeechSynthesizer.swift
//
// On-device text-to-speech for Hermes's replies via AVSpeechSynthesizer.
// Replaces bridge-side TTS: speech starts the instant the response text
// arrives, no cloud synthesis or PCM streaming. Plays through the current
// audio route (glasses in HFP mode). Interruption is stopSpeaking().
//

import AVFoundation
import Foundation
import os

final class HermesSpeechSynthesizer: NSObject, @unchecked Sendable {
    // MARK: - Callbacks (delivered on the main queue)

    /// Fired when an utterance finishes OR is cancelled
    var onFinished: (() -> Void)?

    // MARK: - Private

    private let logger = Logger(subsystem: "com.flowsxr.hermesglasses", category: "tts")
    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?

    override init() {
        // Best installed English voice: premium > enhanced > default.
        // Users can download nicer voices in Settings → Accessibility →
        // Spoken Content → Voices.
        let english = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
        let preferred = english.filter { $0.language == "en-US" }
        voice = (preferred.isEmpty ? english : preferred)
            .max { $0.quality.rawValue < $1.quality.rawValue }

        super.init()
        synthesizer.delegate = self
        if let voice {
            logger.info("TTS voice: \(voice.name, privacy: .public) (quality \(voice.quality.rawValue))")
        }
    }

    // MARK: - Public API

    var isSpeaking: Bool { synthesizer.isSpeaking }

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            DispatchQueue.main.async { [weak self] in self?.onFinished?() }
            return
        }
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = voice
        logger.info("Speaking \(trimmed.count) chars on-device")
        synthesizer.speak(utterance)
    }

    /// Barge-in: stop immediately. The delegate's didCancel fires onFinished.
    func stop() {
        guard synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension HermesSpeechSynthesizer: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        DispatchQueue.main.async { [weak self] in self?.onFinished?() }
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        DispatchQueue.main.async { [weak self] in self?.onFinished?() }
    }
}
