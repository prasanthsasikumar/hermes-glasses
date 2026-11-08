//
// HermesAudioManager.swift
//
// Manages audio capture from Meta Ray-Ban glasses and playback of
// Hermes Agent TTS responses. Uses AVAudioEngine for capture and playback.
//

import AVFoundation
import Foundation
import os

/// Where voice capture (and, on Bluetooth, playback) is routed
enum CaptureRoute {
    /// iPhone built-in mic; playback on the phone speaker
    case phoneMic
    /// Glasses over Bluetooth HFP - bidirectional, but on Display glasses
    /// the firmware shows its CALL SCREEN, covering the lens HUD
    case glassesMic
    /// Earbuds/headset over Bluetooth HFP - mic + voice in the ears while
    /// the glasses' lens stays free for the HUD
    case headsetMic
}

/// Manages audio capture and playback for the Hermes Glasses app
final class HermesAudioManager: NSObject, @unchecked Sendable {
    // MARK: - Callbacks
    //
    // Assigned on the main actor, read on the audio-render thread. They live
    // in one locked struct and the tap snapshots the whole set once per
    // buffer, so a mid-buffer reassignment can't be seen half-applied.

    private struct Callbacks {
        var onAudioChunk: ((Data) -> Void)?
        var onSpeechDetected: (() -> Void)?
        var onSilenceDetected: (() -> Void)?
        var onPlaybackComplete: (() -> Void)?
        var onDebug: ((String) -> Void)?
        var onRawBuffer: ((AVAudioPCMBuffer) -> Void)?
        var onLevel: ((Float) -> Void)?
        var onRouteChanged: (() -> Void)?
    }

    private let callbackLock = OSAllocatedUnfairLock(uncheckedState: Callbacks())

    var onAudioChunk: ((Data) -> Void)? {
        get { callbackLock.withLockUnchecked { $0.onAudioChunk } }
        set { callbackLock.withLockUnchecked { $0.onAudioChunk = newValue } }
    }
    var onSpeechDetected: (() -> Void)? {
        get { callbackLock.withLockUnchecked { $0.onSpeechDetected } }
        set { callbackLock.withLockUnchecked { $0.onSpeechDetected = newValue } }
    }
    var onSilenceDetected: (() -> Void)? {
        get { callbackLock.withLockUnchecked { $0.onSilenceDetected } }
        set { callbackLock.withLockUnchecked { $0.onSilenceDetected = newValue } }
    }
    var onPlaybackComplete: (() -> Void)? {
        get { callbackLock.withLockUnchecked { $0.onPlaybackComplete } }
        set { callbackLock.withLockUnchecked { $0.onPlaybackComplete = newValue } }
    }
    /// Diagnostic messages (mic route, levels) for remote debugging
    var onDebug: ((String) -> Void)? {
        get { callbackLock.withLockUnchecked { $0.onDebug } }
        set { callbackLock.withLockUnchecked { $0.onDebug = newValue } }
    }
    /// Raw tap buffer, pre-conversion - for on-device speech recognition
    var onRawBuffer: ((AVAudioPCMBuffer) -> Void)? {
        get { callbackLock.withLockUnchecked { $0.onRawBuffer } }
        set { callbackLock.withLockUnchecked { $0.onRawBuffer = newValue } }
    }
    /// Mic RMS level (0..~1), throttled to ~4/s - for the UI level meter
    var onLevel: ((Float) -> Void)? {
        get { callbackLock.withLockUnchecked { $0.onLevel } }
        set { callbackLock.withLockUnchecked { $0.onLevel = newValue } }
    }
    /// Fired (on main) after a route/config change re-installed the tap.
    /// Consumers feeding SFSpeech MUST restart their recognition request -
    /// it cannot absorb a buffer-format change mid-request.
    var onRouteChanged: (() -> Void)? {
        get { callbackLock.withLockUnchecked { $0.onRouteChanged } }
        set { callbackLock.withLockUnchecked { $0.onRouteChanged = newValue } }
    }

    /// Converted PCM16 mono 16 kHz samples, delivered ON THE AUDIO THREAD and
    /// ungated by VAD - for `ConversationRecorder`.
    ///
    /// Deliberately NOT `onAudioChunk`, which hops to main: at ~47 buffers a
    /// second, routing a recording through the main queue makes the recording
    /// hostage to whatever the UI is doing. Handlers must not block; the
    /// recorder only enqueues onto its own serial queue.
    ///
    /// This one has its own lock, and it is the ONE callback invoked with a
    /// lock held. `finishConversationCapture` nils it out and then closes the
    /// recorder's file handle, so "no chunk can still be in flight once the
    /// setter returns" has to be a guarantee, not a hope - a snapshot taken
    /// one instruction before the nil-out would otherwise write into a closed
    /// handle. The contract above (enqueue and return, never block, never
    /// call back into this class) is what keeps that safe on a real-time
    /// thread.
    var onRecordChunk: ((Data) -> Void)? {
        get { recordChunkLock.withLockUnchecked { $0 } }
        set { recordChunkLock.withLockUnchecked { $0 = newValue } }
    }

    private let recordChunkLock = OSAllocatedUnfairLock<((Data) -> Void)?>(
        uncheckedState: nil
    )

    // MARK: - Private

    private let logger = Logger(subsystem: "com.flowsxr.hermesglasses", category: "audio")

    // Rebuilt fresh on every startCapture: AVAudioEngine caches the audio
    // graph/hardware formats of the previous route, and starting a stale
    // engine after an HFP route change fails with -10868
    // (kAudioUnitErr_FormatNotSupported). reset() is not enough.
    private var audioEngine = AVAudioEngine()
    private var inputNode: AVAudioNode { audioEngine.inputNode }
    private var outputNode: AVAudioNode { audioEngine.outputNode }
    private let captureFormat: AVAudioFormat

    private var isCapturing: Bool = false
    private var configChangeObserver: NSObjectProtocol?

    /// External-capture mode: no AVAudioEngine, no tap - buffers are pushed
    /// in through `ingest` by whoever owns the microphone (the AiSee kit).
    ///
    /// Written from the session actor and read on the SDK's audio thread at
    /// ~50 buffers a second, so it lives behind the same lock as the rest of
    /// the tap state rather than as a bare `Bool`.
    private var externalCapture: Bool {
        get { tapLock.withLockUnchecked { $0.externalCapture } }
        set { tapLock.withLockUnchecked { $0.externalCapture = newValue } }
    }

    /// Everything the tap block touches. `startCapture`/`rebuildEngine`/
    /// `stopCapture` run off the main actor (they are `async` on a
    /// non-isolated class) while the tap is live on the audio-render thread,
    /// so all of it is read and written concurrently.
    private struct TapState {
        // Lazy conversion state - rebuilt whenever the tap's buffer format changes
        var converter: AVAudioConverter?
        var converterInputFormat: AVAudioFormat?
        var bufferCount: Int = 0
        var lastDebugTime: TimeInterval = 0
        var lastLevelTime: TimeInterval = 0
        // VAD
        var isSpeechActive: Bool = false
        var silenceCounter: Int = 0
        // True while buffers arrive via `ingest` instead of an engine tap
        var externalCapture: Bool = false
    }

    private let tapLock = OSAllocatedUnfairLock(uncheckedState: TapState())

    // VAD tuning
    private let silenceThreshold: Float = 0.015
    private let silenceFrames: Int = 20
    private let vadDisabled: Bool = true

    // Playback - a self-contained clip player, independent of the engine
    private var clipPlayer: AVAudioPlayer?

    override init() {
        // 16 kHz mono PCM16 - the format the bridge expects. This
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

    /// Where playback is going right now ("Speaker", "AiSee-G1", AirPods…).
    var currentOutputName: String {
        let outs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outs.map(\.portName).joined(separator: ", ").isEmpty ? "Unknown" : outs.map(\.portName).joined(separator: ", ")
    }

    /// True when playback is on a Bluetooth output (A2DP/HFP/LE).
    var outputIsBluetooth: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains($0.portType)
        }
    }

    var isUsingBluetoothInput: Bool {
        AVAudioSession.sharedInstance().currentRoute.inputs.contains {
            $0.portType == .bluetoothHFP || $0.portType == .bluetoothA2DP
        }
    }

    /// Heuristic: does this Bluetooth port belong to the glasses (vs
    /// earbuds/headset)? Used to keep headset mode off the glasses' HFP -
    /// their call screen would cover the lens HUD.
    private static let glassesNameMarkers = ["ray-ban", "rayban", "oakley", "meta", "glasses"]

    private static func looksLikeGlasses(_ port: AVAudioSessionPortDescription) -> Bool {
        let name = port.portName.lowercased()
        return glassesNameMarkers.contains { name.contains($0) }
    }

    /// True when the ACTIVE input is the glasses' hands-free link - the
    /// state in which Display glasses show their call screen over the HUD
    var isUsingGlassesInput: Bool {
        AVAudioSession.sharedInstance().currentRoute.inputs.contains {
            ($0.portType == .bluetoothHFP || $0.portType == .bluetoothA2DP)
                && Self.looksLikeGlasses($0)
        }
    }

    /// Start capturing on the requested route. Returns true when the
    /// requested Bluetooth route is actually active - false means the
    /// iPhone mic is in use (by choice, or as fallback when the Bluetooth
    /// route never appeared / no matching device was found).
    @discardableResult
    func startCapture(route: CaptureRoute = .phoneMic) async throws -> Bool {
        guard await requestMicrophonePermission() else {
            logger.error("Microphone permission denied")
            throw HermesAudioError.microphonePermissionDenied
        }

        let session = AVAudioSession.sharedInstance()

        var wantBluetooth = false
        if route != .phoneMic {
            // Mode .default, NOT .voiceChat - its DSP gates speech to the
            // noise floor. HFP is bidirectional: TTS also moves to the
            // chosen device's speakers while this mode is active (by design).
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.allowBluetoothHFP]
            )

            let hfpInputs = (session.availableInputs ?? [])
                .filter { $0.portType == .bluetoothHFP }
            let target: AVAudioSessionPortDescription?
            switch route {
            case .glassesMic:
                target = hfpInputs.first(where: Self.looksLikeGlasses)
                    ?? hfpInputs.first
            case .headsetMic:
                // NEVER fall back to the glasses here - that would put the
                // call screen over the HUD the user chose this mode to keep
                target = hfpInputs.first { !Self.looksLikeGlasses($0) }
            case .phoneMic:
                target = nil
            }

            if let target {
                logger.info("Preferring Bluetooth input: \(target.portName, privacy: .public)")
                try session.setPreferredInput(target)
                try session.setActive(true)
                wantBluetooth = true

                // Wait up to 3s for the Bluetooth route, without blocking the thread
                for _ in 0..<30 where !isUsingBluetoothInput {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            }

            if !wantBluetooth || !isUsingBluetoothInput {
                // Requested device absent or route never materialized -
                // fall back to the iPhone mic so the session still works.
                logger.warning("Bluetooth route unavailable for \(String(describing: route), privacy: .public) - falling back to iPhone mic")
                try? session.setPreferredInput(nil)
                try session.setCategory(
                    .playAndRecord,
                    mode: .default,
                    options: [.defaultToSpeaker]
                )
                try session.setActive(true)
            }
        } else {
            // iPhone mic, voice in the glasses. .allowBluetoothA2DP and
            // NEVER .allowBluetoothHFP: A2DP is output-only, so iOS cannot
            // re-route INPUT to the glasses and kill the tap, and it opens no
            // hands-free link, so Display glasses show no call screen. TTS
            // lands on connected A2DP glasses/earbuds; with none, the speaker.
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetoothA2DP]
            )
            try? session.setPreferredInput(nil)
            try session.setActive(true)
        }

        logger.info("Audio session active. Input route: \(self.currentInputName, privacy: .public)")

        // Route changes (especially to/from HFP) renegotiate the hardware
        // sample rate - let it settle before touching the engine.
        try? await Task.sleep(nanoseconds: 300_000_000)

        // Fresh engine every start: the old instance's cached graph is what
        // produces -10868 after a route change. The old player node dies
        // with the old engine (never detach - that raises NSException).
        rebuildEngine()

        var waited = 0
        while inputNode.outputFormat(forBus: 0).sampleRate == 0, waited < 10 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            waited += 1
        }

        isCapturing = true
        tapLock.withLockUnchecked { state in
            state.bufferCount = 0
            // Defensive: an engine tap and `ingest` must never both feed the
            // pipeline. `stopCapture()` clears this, but a caller that switched
            // routes without one would otherwise leave `ingest` armed alongside
            // the tap installed below.
            state.externalCapture = false
        }
        observeConfigurationChanges()
        installTap()
        do {
            try audioEngine.start()
        } catch {
            // One retry with another fresh engine - the first start can
            // race the route transition
            logger.warning("Engine start failed (\(error.localizedDescription, privacy: .public)) - rebuilding and retrying")
            try? await Task.sleep(nanoseconds: 500_000_000)
            rebuildEngine()
            observeConfigurationChanges()
            installTap()
            try audioEngine.start()
        }
        logger.info("Audio engine started")
        return isUsingBluetoothInput
    }

    /// Start a capture that is fed from OUTSIDE - the AiSee kit delivers its
    /// own 16 kHz PCM over Bluetooth, so there is no iOS input route to open.
    ///
    /// The audio session is configured like the phone route (`.playAndRecord`,
    /// so TTS still plays), plus `.allowBluetoothA2DP` so TTS can reach A2DP
    /// glasses/earbuds. No AVAudioEngine is built,
    /// no tap is installed and no configuration-change observer is registered:
    /// there is no engine whose graph a route change could invalidate. Buffers
    /// arrive through `ingest`.
    func startExternalCapture() async throws {
        guard await requestMicrophonePermission() else {
            logger.error("Microphone permission denied")
            throw HermesAudioError.microphonePermissionDenied
        }

        let session = AVAudioSession.sharedInstance()
        // .allowBluetoothA2DP (not HFP): the glasses' mic is NOT an iOS input
        // here, so nothing wants a hands-free link - but TTS should still be
        // able to land on A2DP glasses/earbuds when a pair is connected.
        try session.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.defaultToSpeaker, .allowBluetoothA2DP]
        )
        // Parity with the phone route's fallback: a preferred input left over
        // from a Bluetooth route would keep pointing the session at a mic this
        // capture does not use.
        try? session.setPreferredInput(nil)
        try session.setActive(true)

        // The incoming format belongs to the kit, not to the last iOS route -
        // drop any converter cached for that route.
        clearConverter()
        tapLock.withLockUnchecked { state in
            state.bufferCount = 0
            state.externalCapture = true
        }
        isCapturing = true

        logger.info("External capture active (buffers arrive via ingest). Output route: \(session.currentRoute.outputs.first?.portName ?? "none", privacy: .public)")
        sendDebug("external capture started")
    }

    /// Feed one buffer into the same pipeline the engine tap uses.
    ///
    /// Called on the provider's audio thread (~50 buffers/s). Everything
    /// downstream is already written for the audio-render thread, so this is
    /// safe from any thread; it must never be called on the main actor's
    /// behalf expecting main-actor isolation.
    func ingest(_ buffer: AVAudioPCMBuffer) {
        guard externalCapture else { return }
        processInputBuffer(buffer)
    }

    /// Replace the engine with a fresh instance, discarding all cached
    /// graph state. The old engine (and its attached player) is released.
    private func rebuildEngine() {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        audioEngine.stop()
        clearConverter()
        audioEngine = AVAudioEngine()
    }

    /// Drop the cached converter so the next tap buffer rebuilds one for the
    /// new route's format.
    private func clearConverter() {
        tapLock.withLockUnchecked { state in
            state.converter = nil
            state.converterInputFormat = nil
        }
    }

    func stopCapture() {
        let wasExternal = externalCapture
        isCapturing = false
        externalCapture = false
        clipPlayer?.stop()
        clipPlayer = nil
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configChangeObserver = nil
        }
        // External capture never built an engine or installed a tap.
        // `inputNode` is lazy - touching it here would instantiate the input
        // hardware unit for no reason.
        if !wasExternal {
            inputNode.removeTap(onBus: 0)
            audioEngine.stop()
        }
        clearConverter()
        try? AVAudioSession.sharedInstance().setActive(false)
    }

    // MARK: - Playback
    //
    // TTS plays through AVAudioPlayer, NOT the capture engine. AVAudioEngine
    // playback proved unshippable against Bluetooth HFP route flaps: config
    // changes flush scheduled buffers, and AVAudioPlayerNode.play() raises
    // uncatchable NSExceptions when the engine stops under it (three
    // distinct SIGABRTs in the field). AVAudioPlayer owns its rendering,
    // survives route changes, and always calls its delegate on completion.

    func playResponse(_ audioData: Data) async {
        guard !audioData.isEmpty else {
            onPlaybackComplete?()
            return
        }

        let wav = Self.wavContainer(pcm16: audioData, sampleRate: 24000)
        do {
            let player = try AVAudioPlayer(data: wav)
            player.delegate = self
            clipPlayer?.stop()
            clipPlayer = player
            logger.info("Playing TTS response: \(audioData.count) bytes (\(String(format: "%.1f", player.duration))s)")
            player.play()
        } catch {
            logger.error("AVAudioPlayer failed: \(error.localizedDescription, privacy: .public)")
            onPlaybackComplete?()
        }
    }

    /// Stop the current TTS clip (barge-in). AVAudioPlayer.stop() does not
    /// call the delegate, so completion is fired here.
    func stopPlayback() {
        guard let player = clipPlayer else { return }
        player.stop()
        clipPlayer = nil
        logger.info("Playback interrupted")
        DispatchQueue.main.async { [weak self] in
            self?.onPlaybackComplete?()
        }
    }

    /// Wrap raw PCM16 mono samples in a WAV container for AVAudioPlayer
    private static func wavContainer(pcm16: Data, sampleRate: Int) -> Data {
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }

        var wav = Data()
        wav.append("RIFF".data(using: .ascii)!)
        wav.append(le32(UInt32(36 + pcm16.count)))
        wav.append("WAVE".data(using: .ascii)!)
        wav.append("fmt ".data(using: .ascii)!)
        wav.append(le32(16))                              // fmt chunk size
        wav.append(le16(1))                               // PCM
        wav.append(le16(1))                               // mono
        wav.append(le32(UInt32(sampleRate)))
        wav.append(le32(UInt32(sampleRate * 2)))          // byte rate
        wav.append(le16(2))                               // block align
        wav.append(le16(16))                              // bits/sample
        wav.append("data".data(using: .ascii)!)
        wav.append(le32(UInt32(pcm16.count)))
        wav.append(pcm16)
        return wav
    }

    /// Configure a playback-only audio session so the Sound test works
    /// without a capture session running
    func preparePlaybackOnly() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
    }

    /// 1.5 s 440 Hz sine as PCM16 mono 24 kHz - same format as bridge TTS,
    /// so playing it exercises the exact TTS playback path
    static func makeTestTone(duration: Double = 1.5) -> Data {
        let sampleRate = 24000.0
        let frames = Int(duration * sampleRate)
        var samples = [Int16](repeating: 0, count: frames)
        for i in 0..<frames {
            let t = Double(i) / sampleRate
            // Gentle fade in/out to avoid clicks
            let envelope = min(1.0, min(Double(i), Double(frames - i)) / 1200.0)
            samples[i] = Int16(sin(2.0 * .pi * 440.0 * t) * 12000.0 * envelope)
        }
        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
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
            self.logger.info("Engine configuration changed - reinstalling tap. Route: \(self.currentInputName, privacy: .public)")
            self.inputNode.removeTap(onBus: 0)
            self.installTap()
            if !self.audioEngine.isRunning {
                do {
                    try self.audioEngine.start()
                } catch {
                    self.logger.error("Failed to restart engine: \(error.localizedDescription, privacy: .public)")
                }
            }

            self.onRouteChanged?()
        }
    }

    private func installTap() {
        let inputFormat = inputNode.outputFormat(forBus: 0)
        logger.info("Installing tap. Input format: \(inputFormat.sampleRate, privacy: .public) Hz, \(inputFormat.channelCount, privacy: .public) ch")

        let session = AVAudioSession.sharedInstance()
        let inputs = session.currentRoute.inputs
            .map { "\($0.portName) (\($0.portType.rawValue))" }
            .joined(separator: ", ")
        sendDebug("tap installed: route=[\(inputs)] format=\(inputFormat.sampleRate)Hz/\(inputFormat.channelCount)ch gain=\(session.inputGain)")

        // format: nil - the tap follows the node's live format. Passing an
        // explicit format raises NSException (SIGABRT) when the cached
        // format mismatches the hardware mid-route-change (e.g. switching
        // to Bluetooth HFP). The converter is built lazily per buffer
        // format instead.
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1024,
            format: nil
        ) { [weak self] buffer, _ in
            self?.processInputBuffer(buffer)
        }
    }

    private func processInputBuffer(_ buffer: AVAudioPCMBuffer) {
        // Audio-render thread. Every critical section below is a handful of
        // stores; the conversion, the callbacks and the logging all happen
        // with no lock held.
        let now = Date().timeIntervalSince1970
        let entry = tapLock.withLockUnchecked { state -> (converter: AVAudioConverter?, count: Int, level: Bool, debug: Bool) in
            state.bufferCount += 1
            let level = now - state.lastLevelTime > 0.25
            if level { state.lastLevelTime = now }
            let debug = now - state.lastDebugTime > 1.0
            if debug { state.lastDebugTime = now }
            let reusable = state.converterInputFormat == buffer.format
            return (reusable ? state.converter : nil, state.bufferCount, level, debug)
        }

        // (Re)build the converter whenever the incoming format changes -
        // route switches change the sample rate under our feet. Building one
        // allocates, so it happens outside the critical section. A buffer
        // that already IS the capture format skips the converter entirely.
        let passthrough = isPassthrough(buffer.format)
        var converter = entry.converter
        if !passthrough, converter == nil {
            converter = AVAudioConverter(from: buffer.format, to: captureFormat)
            let format = buffer.format
            tapLock.withLockUnchecked { state in
                state.converter = converter
                state.converterInputFormat = format
            }
        }
        if !passthrough, converter == nil { return }

        let count = entry.count
        if count == 1 || count % 100 == 0 {
            logger.info("Tap delivered buffer #\(count, privacy: .public) (\(buffer.frameLength, privacy: .public) frames)")
        }

        // One snapshot per buffer: the set of callbacks cannot change under
        // the rest of this function.
        let callbacks = callbackLock.withLockUnchecked { $0 }

        callbacks.onRawBuffer?(buffer)

        if entry.level, let onLevel = callbacks.onLevel {
            let level = rawFloatRMS(buffer)
            DispatchQueue.main.async { onLevel(max(0, level)) }
        }

        let outputBuffer: AVAudioPCMBuffer?
        if passthrough {
            outputBuffer = buffer
        } else if let converter {
            outputBuffer = convertBuffer(buffer, using: converter)
        } else {
            outputBuffer = nil
        }
        guard let outputBuffer else { return }

        guard let channelData = outputBuffer.int16ChannelData else { return }
        let frameLength = Int(outputBuffer.frameLength)
        guard frameLength > 0 else { return }
        let data = Data(
            bytes: channelData[0],
            count: frameLength * MemoryLayout<Int16>.size
        )

        // Straight to the recorder, on this thread, before any VAD gate: a
        // recording of a conversation must contain the quiet half of it.
        // Invoked under its own lock - see `onRecordChunk`.
        recordChunkLock.withLockUnchecked { handler in handler?(data) }

        let rms = computeRMS(channelData[0], frameLength: frameLength)
        let isVoice = rms > silenceThreshold

        // Periodic level diagnostics: raw float level straight off the mic
        // vs. level after conversion, plus the active input route
        if entry.debug {
            let raw = rawFloatRMS(buffer)
            let route = AVAudioSession.sharedInstance()
                .currentRoute.inputs.first?.portName ?? "none"
            sendDebug(String(
                format: "levels raw=%.4f converted=%.4f route=%@ frames=%d",
                raw, rms, route, buffer.frameLength
            ), to: callbacks.onDebug)
        }

        // Advance the speech/silence state machine even when VAD gating is
        // off, so end-of-utterance is still detected.
        let (wasSpeechActive, transition) = tapLock.withLockUnchecked {
            state -> (Bool, VADTransition) in
            let wasSpeechActive = state.isSpeechActive
            if isVoice {
                state.silenceCounter = 0
                guard !wasSpeechActive else { return (wasSpeechActive, .none) }
                state.isSpeechActive = true
                return (wasSpeechActive, .speechStarted)
            }
            guard wasSpeechActive else { return (wasSpeechActive, .none) }
            state.silenceCounter += 1
            guard state.silenceCounter >= silenceFrames else {
                return (wasSpeechActive, .none)
            }
            state.isSpeechActive = false
            state.silenceCounter = 0
            return (wasSpeechActive, .silenceStarted)
        }

        // Send audio whenever VAD is disabled or speech is in progress (the
        // gate reads the state as it was BEFORE this buffer advanced it).
        // The bridge's legacy audio path has no app-side consumer today, so
        // skip the hop to main entirely when nobody is listening - at ~47
        // buffers a second an empty dispatch is pure overhead.
        if let onAudioChunk = callbacks.onAudioChunk,
           vadDisabled || isVoice || wasSpeechActive {
            DispatchQueue.main.async { onAudioChunk(data) }
        }

        switch transition {
        case .none:
            break
        case .speechStarted:
            if let onSpeechDetected = callbacks.onSpeechDetected {
                DispatchQueue.main.async { onSpeechDetected() }
            }
        case .silenceStarted:
            if let onSilenceDetected = callbacks.onSilenceDetected {
                DispatchQueue.main.async { onSilenceDetected() }
            }
        }
    }

    private enum VADTransition {
        case none
        case speechStarted
        case silenceStarted
    }

    /// True when `buffer`'s format can go downstream untouched.
    ///
    /// Everything after conversion reads `int16ChannelData[0]` and
    /// `frameLength`, and for a MONO Int16 buffer that is the same memory
    /// whether the format calls itself interleaved or not - so an exact
    /// format match is not required, only Int16 / same rate / one channel.
    /// That matters for the AiSee kit, whose sink emits 16 kHz Int16 mono
    /// marked `interleaved: true` while `captureFormat` is the same thing
    /// marked non-interleaved: without this the hot path (~50 buffers/s)
    /// would run an AVAudioConverter that does nothing.
    private func isPassthrough(_ format: AVAudioFormat) -> Bool {
        if format == captureFormat { return true }
        return format.commonFormat == captureFormat.commonFormat
            && format.sampleRate == captureFormat.sampleRate
            && format.channelCount == 1
            && captureFormat.channelCount == 1
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

    /// `to:` lets the tap reuse the handler it already snapshotted rather
    /// than re-reading it; callers off the audio thread pass nothing.
    private func sendDebug(_ message: String, to handler: ((String) -> Void)? = nil) {
        logger.info("\(message, privacy: .public)")
        guard let handler = handler ?? onDebug else { return }
        DispatchQueue.main.async { handler(message) }
    }

    /// RMS of the untouched buffer straight off the input, before conversion.
    ///
    /// An engine tap hands over float buffers; the AiSee kit hands over Int16
    /// ones, and an Int16 buffer's `floatChannelData` is nil. Without the
    /// second branch this returned -1 for every AiSee buffer, so the UI level
    /// meter (which clamps at 0) sat dead flat for the whole session and the
    /// periodic "levels raw=..." diagnostic was meaningless.
    private func rawFloatRMS(_ buffer: AVAudioPCMBuffer) -> Float {
        guard buffer.frameLength > 0 else { return -1 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        if let channels = buffer.floatChannelData {
            for i in 0..<n {
                let s = channels[0][i]
                sum += s * s
            }
        } else if let channels = buffer.int16ChannelData {
            // `stride` is 1 for non-interleaved and the channel count for
            // interleaved, so this reads channel 0 either way.
            let step = buffer.stride
            for i in 0..<n {
                let s = Float(channels[0][i * step]) / 32768.0
                sum += s * s
            }
        } else {
            return -1
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

}

// MARK: - AVAudioPlayerDelegate

extension HermesAudioManager: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.logger.info("TTS playback finished (success=\(flag))")
            self.clipPlayer = nil
            self.onPlaybackComplete?()
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.logger.error("TTS decode error: \(error?.localizedDescription ?? "?", privacy: .public)")
            self.clipPlayer = nil
            self.onPlaybackComplete?()
        }
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
