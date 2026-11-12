//
// HermesSpeechSynthesizer.swift
//
// Hermes's voice. One queue of short pieces of speech, spoken in order, by
// one of two voices:
//
//  - ElevenLabs (natural) when a key is set: each piece is fetched as MP3
//    and played with AVAudioPlayer. Pieces are fetched ahead while earlier
//    ones play, so after the first there is no wait between them.
//  - The iPhone's own voice (AVSpeechSynthesizer) otherwise - and as the
//    fallback for ANY piece ElevenLabs fails to deliver. A reply is never
//    lost to a network error; it just sounds more robotic.
//
// Speech can be fed as a stream (`beginStream` / `enqueue` / `endStream`)
// so the first sentence of an answer is spoken while the model is still
// writing the rest; `speak(_:)` is the one-shot form of the same thing.
// `onFinished` fires ONCE per stream, when everything has been spoken or
// the stream was stopped.
//
// Main-thread only: every entry point is called from the main actor, and
// the delegate callbacks hop to the main queue before touching state.
// Playback uses AVAudioPlayer, never the capture engine (see the Playback
// note in HermesAudioManager).
//

import AVFoundation
import Foundation
import os

final class HermesSpeechSynthesizer: NSObject, @unchecked Sendable {
    // MARK: - Callbacks (delivered on the main queue)

    /// Fired when a stream finishes OR is stopped.
    var onFinished: (() -> Void)?
    /// ElevenLabs rejected the key (or the plan) - the natural voice is off
    /// until the app restarts, and the iPhone voice has taken over.
    var onVoiceFallback: ((String) -> Void)?

    // MARK: - Private

    private struct Segment {
        let id: Int
        let text: String
        var audio: Data?
        var loading = false
        var failed = false
    }

    /// More than this and a rate-limited ElevenLabs plan starts refusing.
    private static let maxConcurrentFetches = 2

    private let logger = Logger(subsystem: "com.flowsxr.hermesglasses", category: "tts")
    private let synthesizer = AVSpeechSynthesizer()
    private let voice: AVSpeechSynthesisVoice?

    private var queue: [Segment] = []
    private var nextID = 0
    /// Bumped whenever the current stream is replaced or stopped; late
    /// fetches and callbacks from an older stream compare and drop out.
    private var generation = 0
    private var active = false
    private var streamOpen = false
    private var useCloud = false
    /// A fatal ElevenLabs error (bad key, no access) this app run.
    private var cloudDisabled = false
    /// True while the head of the queue is audible.
    private var headPlaying = false
    private var player: AVAudioPlayer?
    private var currentUtterance: AVSpeechUtterance?
    private var streamStartedAt = Date()
    private var firstAudioLogged = false

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

    /// True from `beginStream`/`speak` until the last piece has been spoken.
    var isSpeaking: Bool { active }

    /// Speak a whole reply. Replaces anything already being spoken.
    func speak(_ text: String) {
        beginStream()
        for piece in SentenceChunker.pieces(of: text) { enqueue(piece) }
        endStream()
    }

    /// Start a reply whose text will arrive in pieces. Replaces anything
    /// already being spoken (silently - the old stream's `onFinished` is
    /// not fired, the new one's will be).
    ///
    /// Returns the stream's token. A caller that feeds a stream over time
    /// passes it back to `enqueue`/`endStream`, so pieces of a reply that
    /// was interrupted can never leak into whatever is spoken next.
    @discardableResult
    func beginStream() -> Int {
        cancel()
        active = true
        streamOpen = true
        useCloud = ElevenLabsVoice.isActive && !cloudDisabled
        streamStartedAt = Date()
        firstAudioLogged = false
        return generation
    }

    /// Add a piece to the current stream. Ignored once the stream was
    /// stopped - an answer that keeps arriving after a barge-in stays quiet.
    func enqueue(_ text: String, stream: Int? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard stream == nil || stream == generation else { return }
        guard active, streamOpen, !trimmed.isEmpty else { return }
        nextID += 1
        queue.append(Segment(id: nextID, text: trimmed))
        pump()
    }

    /// No more pieces are coming; `onFinished` fires when the queue drains.
    func endStream(stream: Int? = nil) {
        guard stream == nil || stream == generation else { return }
        guard active else { return }
        streamOpen = false
        pump()
    }

    /// Barge-in: stop immediately and fire `onFinished`.
    func stop() {
        guard active else { return }
        cancel()
        fireFinished()
    }

    // MARK: - Queue

    private func cancel() {
        generation += 1
        queue = []
        active = false
        streamOpen = false
        headPlaying = false
        player?.stop()
        player = nil
        currentUtterance = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }

    private func fireFinished() {
        let g = generation
        DispatchQueue.main.async { [weak self] in
            // A new stream began in the meantime: its own finish will fire.
            guard let self, self.generation == g else { return }
            self.onFinished?()
        }
    }

    /// Fetch ahead, and start the head of the queue if nothing is audible.
    private func pump() {
        guard active else { return }

        if useCloud {
            var loading = queue.filter(\.loading).count
            for i in queue.indices where loading < Self.maxConcurrentFetches {
                guard queue[i].audio == nil, !queue[i].failed, !queue[i].loading else { continue }
                queue[i].loading = true
                loading += 1
                fetch(queue[i])
            }
        }

        guard !headPlaying else { return }
        guard let head = queue.first else {
            if !streamOpen {
                active = false
                fireFinished()
            }
            return
        }
        if useCloud, !head.failed {
            guard let audio = head.audio else { return }   // still on its way
            if !play(audio) { speakOnDevice(head.text) }
        } else {
            speakOnDevice(head.text)
        }
    }

    private func fetch(_ segment: Segment) {
        let g = generation
        let id = segment.id
        let text = segment.text
        let started = Date()
        Task { [weak self] in
            let result: Result<Data, Error>
            do { result = .success(try await ElevenLabsVoice.fetch(text)) }
            catch { result = .failure(error) }
            await MainActor.run { self?.fetched(id: id, generation: g, result: result, started: started) }
        }
    }

    private func fetched(id: Int, generation g: Int, result: Result<Data, Error>, started: Date) {
        guard g == generation, let i = queue.firstIndex(where: { $0.id == id }) else { return }
        queue[i].loading = false
        switch result {
        case .success(let data):
            queue[i].audio = data
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            logger.info("ElevenLabs: \(self.queue[i].text.count) chars in \(ms) ms")
        case .failure(let error):
            queue[i].failed = true
            logger.error("ElevenLabs failed, using the iPhone voice: \(error.localizedDescription, privacy: .public)")
            if let failure = error as? ElevenLabsVoice.Failure, failure.isFatal {
                cloudDisabled = true
                useCloud = false
                onVoiceFallback?(failure.message)
            }
        }
        pump()
    }

    private func headFinished() {
        headPlaying = false
        player = nil
        currentUtterance = nil
        if !queue.isEmpty { queue.removeFirst() }
        pump()
    }

    private func noteFirstAudio(_ kind: String) {
        guard !firstAudioLogged else { return }
        firstAudioLogged = true
        let ms = Int(Date().timeIntervalSince(streamStartedAt) * 1000)
        logger.info("First audio (\(kind, privacy: .public)) \(ms) ms after the reply began")
        NSLog("[Hermes] voice: first audio (\(kind)) \(ms) ms after the reply began")
    }

    // MARK: - The two voices

    private func play(_ audio: Data) -> Bool {
        guard let player = try? AVAudioPlayer(data: audio) else { return false }
        player.delegate = self
        guard player.play() else { return false }
        self.player = player
        headPlaying = true
        noteFirstAudio("ElevenLabs")
        return true
    }

    private func speakOnDevice(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        currentUtterance = utterance
        headPlaying = true
        noteFirstAudio("iPhone voice")
        synthesizer.speak(utterance)
    }
}

// MARK: - AVAudioPlayerDelegate

extension HermesSpeechSynthesizer: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.player === player else { return }
            self.headFinished()
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.player === player else { return }
            self.logger.error("Voice clip decode error: \(error?.localizedDescription ?? "?", privacy: .public)")
            self.headFinished()
        }
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension HermesSpeechSynthesizer: AVSpeechSynthesizerDelegate {
    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.currentUtterance === utterance else { return }
            self.headFinished()
        }
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        // Only reached for an utterance we did not cancel ourselves
        // (`cancel()` clears `currentUtterance` first) - e.g. the system
        // interrupting speech. Move on rather than hanging the queue.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.currentUtterance === utterance else { return }
            self.headFinished()
        }
    }
}
