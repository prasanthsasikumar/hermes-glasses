//
// HermesCameraManager.swift
//
// Captures photos from the Meta Ray-Ban glasses camera via the DAT SDK.
// Owns the camera stream lifecycle: a fresh stream is opened for every
// capture and stopped when the capture finishes, so the glasses don't
// drain battery between shots. Streams are not cached/reused across
// captures - DAT streams are treated as one-shot.
//

import Foundation
import MWDATCamera
import MWDATCore
import UIKit
import os

enum HermesCameraError: LocalizedError {
    case noSession
    case streamUnavailable
    case captureFailed
    case timeout
    case captureInProgress
    case streamInUse

    var errorDescription: String? {
        switch self {
        case .noSession:
            return "Glasses session is not active."
        case .streamUnavailable:
            return "Could not open the glasses camera stream."
        case .captureFailed:
            return "The glasses camera did not accept the capture request."
        case .timeout:
            return "Timed out waiting for the glasses camera."
        case .captureInProgress:
            return "A photo capture is already in progress."
        case .streamInUse:
            return "The glasses camera is already streaming."
        }
    }
}

final class HermesCameraManager: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.flowsxr.hermesglasses", category: "camera")

    /// Diagnostic breadcrumbs (stream states, timings) - surfaced in the
    /// bridge log via the debug channel
    var onDebug: ((String) -> Void)?

    /// All mutable state lives behind one lock so `configure()`/`reset()`
    /// are safe against an in-flight `capturePhoto()`.
    private struct State {
        var deviceSession: DeviceSession?
        var captureInFlight = false
        // Live-stream mode (Lens view). A deliberate exception to the
        // one-shot-stream rule: exactly one persistent stream, torn down
        // by stopLiveStream(). While it runs, capturePhoto() serves the
        // latest live frame instead of opening a competing stream.
        var liveStream: MWDATCamera.Stream?
        var liveTokens: [AnyListenerToken] = []
        var latestLiveFrame: VideoFrame?
    }

    private let stateLock = OSAllocatedUnfairLock(uncheckedState: State())

    func configure(session: DeviceSession) {
        stateLock.withLockUnchecked { state in
            state.deviceSession = session
        }
    }

    func reset() {
        stateLock.withLockUnchecked { state in
            state.deviceSession = nil
        }
    }

    /// Capture a single JPEG from the glasses camera.
    func capturePhoto() async throws -> Data {
        // While the Lens live stream runs, the camera is taken - serve the
        // capture from the freshest live frame instead of opening a second
        // stream (voice-loop visual queries keep working during streaming).
        let liveFrame = stateLock.withLockUnchecked { state -> VideoFrame? in
            state.liveStream != nil ? state.latestLiveFrame : nil
        }
        if let liveFrame {
            guard let image = liveFrame.makeUIImage(),
                  let jpeg = image.jpegData(compressionQuality: 0.85) else {
                throw HermesCameraError.captureFailed
            }
            debug("camera: photo served from live frame (\(jpeg.count) bytes)")
            return jpeg
        }

        enum Entry {
            case busy
            case noSession
            case proceed(DeviceSession)
        }

        let entry: Entry = stateLock.withLockUnchecked { state in
            if state.captureInFlight { return .busy }
            guard let session = state.deviceSession else { return .noSession }
            state.captureInFlight = true
            return .proceed(session)
        }

        let session: DeviceSession
        switch entry {
        case .busy:
            throw HermesCameraError.captureInProgress
        case .noSession:
            throw HermesCameraError.noSession
        case .proceed(let s):
            session = s
        }
        defer { stateLock.withLockUnchecked { $0.captureInFlight = false } }

        // Same lightweight config as Meta's CameraAccess sample - the video
        // stream is just a carrier for photo capture, keep it cheap
        let config = StreamConfiguration(
            videoCodec: .raw,
            resolution: .low,
            frameRate: 24
        )
        guard let stream = try session.addStream(config: config) else {
            debug("camera: addStream returned nil")
            throw HermesCameraError.streamUnavailable
        }
        debug("camera: stream created, state=\(stream.state)")

        // Report every state transition while this capture runs
        let stateToken = stream.statePublisher.listen { [weak self] state in
            self?.debug("camera: state → \(state)")
        }
        defer { Task { await stateToken.cancel() } }

        // The SDK reports WHY a stream dies here - without this listener
        // an aborted stream looks like a silent timeout
        let errorToken = stream.errorPublisher.listen { [weak self] streamError in
            self?.debug("camera: ERROR → \(streamError)")
        }
        defer { Task { await errorToken.cancel() } }

        // The stream must run only while a capture is in flight. Register
        // the stop before starting it so every exit path - including a
        // start-timeout - guarantees the stream is torn down. Streams are
        // one-shot: never cached or reused across captures.
        defer { stream.stop() }

        let started = Date()
        if stream.state != .streaming {
            stream.start()
            // First start can take several seconds (camera sensor + LED
            // wake). The bridge waits 25 s, so 10+10 fits comfortably.
            try await waitForStreaming(stream, timeout: 10.0)
        }
        debug(String(format: "camera: streaming after %.1fs - capturing",
                     Date().timeIntervalSince(started)))

        let photo = try await awaitPhotoData(stream, timeout: 10.0)
        debug(String(format: "camera: photo %d bytes in %.1fs total",
                     photo.count, Date().timeIntervalSince(started)))
        return photo
    }

    // MARK: - Live stream (Lens view)

    /// Start a persistent video stream from the glasses. `onFrame` fires on
    /// an SDK thread for every frame; hop to the main actor before touching
    /// UI state. Throws if a photo capture is mid-flight or a live stream
    /// is already running.
    func startLiveStream(
        onFrame: @escaping @Sendable (VideoFrame) -> Void,
        onError: @escaping @Sendable (String) -> Void
    ) async throws {
        enum Entry {
            case noSession, busy, inUse
            case proceed(DeviceSession)
        }
        let entry: Entry = stateLock.withLockUnchecked { state in
            guard let session = state.deviceSession else { return .noSession }
            if state.captureInFlight { return .busy }
            if state.liveStream != nil { return .inUse }
            return .proceed(session)
        }
        let session: DeviceSession
        switch entry {
        case .noSession: throw HermesCameraError.noSession
        case .busy: throw HermesCameraError.captureInProgress
        case .inUse: throw HermesCameraError.streamInUse
        case .proceed(let s): session = s
        }

        // Highest resolution the SDK offers - snaps are cropped from these
        // frames. Drop to .medium if streaming proves choppy on device.
        let config = StreamConfiguration(
            videoCodec: .raw,
            resolution: .high,
            frameRate: 24
        )
        guard let stream = try session.addStream(config: config) else {
            debug("lens: addStream returned nil")
            throw HermesCameraError.streamUnavailable
        }
        debug("lens: live stream created, state=\(stream.state)")

        let frameToken = stream.videoFramePublisher.listen { [weak self] frame in
            self?.stateLock.withLockUnchecked { $0.latestLiveFrame = frame }
            onFrame(frame)
        }
        let errorToken = stream.errorPublisher.listen { [weak self] streamError in
            self?.debug("lens: ERROR → \(streamError)")
            onError("\(streamError)")
        }
        let stateToken = stream.statePublisher.listen { [weak self] state in
            self?.debug("lens: state → \(state)")
        }

        stateLock.withLockUnchecked { state in
            state.liveStream = stream
            state.liveTokens = [frameToken, errorToken, stateToken]
        }

        do {
            if stream.state != .streaming {
                stream.start()
                try await waitForStreaming(stream, timeout: 10.0)
            }
        } catch {
            stopLiveStream()
            throw error
        }
        debug("lens: live stream running")
    }

    /// Tear down the live stream. Safe to call when no stream is running.
    func stopLiveStream() {
        let (stream, tokens): (MWDATCamera.Stream?, [AnyListenerToken]) =
            stateLock.withLockUnchecked { state in
                let out = (state.liveStream, state.liveTokens)
                state.liveStream = nil
                state.liveTokens = []
                state.latestLiveFrame = nil
                return out
            }
        stream?.stop()
        if stream != nil { debug("lens: live stream stopped") }
        Task {
            for token in tokens { await token.cancel() }
        }
    }

    // MARK: - Private

    private func debug(_ message: String) {
        logger.info("\(message, privacy: .public)")
        DispatchQueue.main.async { [weak self] in
            self?.onDebug?(message)
        }
    }

    private func waitForStreaming(
        _ stream: MWDATCamera.Stream,
        timeout: TimeInterval
    ) async throws {
        let done = OSAllocatedUnfairLock(initialState: false)
        var token: AnyListenerToken?
        var timeoutTask: Task<Void, Never>?

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                token = stream.statePublisher.listen { state in
                    switch state {
                    case .streaming:
                        done.withLock { finished in
                            guard !finished else { return }
                            finished = true
                            cont.resume()
                        }
                    case .stopped:
                        // Stream aborted before reaching .streaming - fail
                        // fast instead of burning the whole timeout
                        done.withLock { finished in
                            guard !finished else { return }
                            finished = true
                            cont.resume(throwing: HermesCameraError.streamUnavailable)
                        }
                    default:
                        break
                    }
                }

                // Already streaming before the listener attached?
                if stream.state == .streaming {
                    done.withLock { finished in
                        guard !finished else { return }
                        finished = true
                        cont.resume()
                    }
                }

                timeoutTask = Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    done.withLock { finished in
                        guard !finished else { return }
                        finished = true
                        cont.resume(throwing: HermesCameraError.timeout)
                    }
                }
            }
        } catch {
            timeoutTask?.cancel()
            if let token { await token.cancel() }
            throw error
        }

        timeoutTask?.cancel()
        if let token { await token.cancel() }
    }

    private func awaitPhotoData(
        _ stream: MWDATCamera.Stream,
        timeout: TimeInterval
    ) async throws -> Data {
        let done = OSAllocatedUnfairLock(initialState: false)
        var token: AnyListenerToken?
        var timeoutTask: Task<Void, Never>?

        let data: Data
        do {
            data = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                token = stream.photoDataPublisher.listen { photo in
                    done.withLock { finished in
                        guard !finished else { return }
                        finished = true
                        cont.resume(returning: photo.data)
                    }
                }

                if !stream.capturePhoto(format: .jpeg) {
                    done.withLock { finished in
                        guard !finished else { return }
                        finished = true
                        cont.resume(throwing: HermesCameraError.captureFailed)
                    }
                }

                timeoutTask = Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    done.withLock { finished in
                        guard !finished else { return }
                        finished = true
                        cont.resume(throwing: HermesCameraError.timeout)
                    }
                }
            }
        } catch {
            timeoutTask?.cancel()
            if let token { await token.cancel() }
            throw error
        }

        timeoutTask?.cancel()
        if let token { await token.cancel() }
        logger.info("Photo captured: \(data.count) bytes")
        return data
    }
}
