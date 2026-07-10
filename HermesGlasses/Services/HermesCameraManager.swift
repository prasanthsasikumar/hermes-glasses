//
// HermesCameraManager.swift
//
// Captures photos from the Meta Ray-Ban glasses camera via the DAT SDK.
// Owns the camera stream lifecycle: the stream runs only while a photo
// is being captured, so the glasses don't drain battery between shots.
//

import Foundation
import MWDATCamera
import MWDATCore
import os

enum HermesCameraError: LocalizedError {
    case noSession
    case streamUnavailable
    case captureFailed
    case timeout
    case captureInProgress

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
        }
    }
}

final class HermesCameraManager: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.flowsxr.hermes-glasses", category: "camera")

    /// All mutable state lives behind one lock so `configure()`/`reset()`
    /// are safe against an in-flight `capturePhoto()`.
    private struct State {
        var deviceSession: DeviceSession?
        var stream: MWDATCamera.Stream?
        var captureInFlight = false
    }

    private let stateLock = OSAllocatedUnfairLock(uncheckedState: State())

    func configure(session: DeviceSession) {
        let streamToStop: MWDATCamera.Stream? = stateLock.withLockUnchecked { state in
            // If a capture is in flight, don't stop its stream out from
            // under it — just drop the stored reference; the in-flight
            // capture holds its own local reference and stops it via defer.
            let stale = state.captureInFlight ? nil : state.stream
            state.stream = nil
            state.deviceSession = session
            return stale
        }
        streamToStop?.stop()
    }

    func reset() {
        let streamToStop: MWDATCamera.Stream? = stateLock.withLockUnchecked { state in
            let stale = state.captureInFlight ? nil : state.stream
            state.stream = nil
            state.deviceSession = nil
            return stale
        }
        streamToStop?.stop()
    }

    /// Capture a single JPEG from the glasses camera.
    func capturePhoto() async throws -> Data {
        enum Entry {
            case busy
            case noSession
            case proceed(DeviceSession, MWDATCamera.Stream?)
        }

        let entry: Entry = stateLock.withLockUnchecked { state in
            if state.captureInFlight { return .busy }
            guard let session = state.deviceSession else { return .noSession }
            state.captureInFlight = true
            return .proceed(session, state.stream)
        }

        let session: DeviceSession
        let existing: MWDATCamera.Stream?
        switch entry {
        case .busy:
            throw HermesCameraError.captureInProgress
        case .noSession:
            throw HermesCameraError.noSession
        case .proceed(let s, let st):
            session = s
            existing = st
        }
        defer { stateLock.withLockUnchecked { $0.captureInFlight = false } }

        let stream: MWDATCamera.Stream
        if let existing {
            stream = existing
        } else {
            guard let created = try session.addStream() else {
                throw HermesCameraError.streamUnavailable
            }
            stateLock.withLockUnchecked { state in
                // Only keep the stream for reuse if the session hasn't been
                // swapped by configure()/reset() in the meantime.
                if state.deviceSession === session {
                    state.stream = created
                }
            }
            stream = created
        }

        // The stream must run only while a capture is in flight. Register
        // the stop before starting it so every exit path — including a
        // start-timeout — guarantees the stream is torn down.
        defer { stream.stop() }

        if stream.state != .streaming {
            stream.start()
            try await waitForStreaming(stream, timeout: 6.0)
        }

        logger.info("Camera streaming — capturing photo")
        return try await awaitPhotoData(stream, timeout: 8.0)
    }

    // MARK: - Private

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
                    if state == .streaming {
                        done.withLock { finished in
                            guard !finished else { return }
                            finished = true
                            cont.resume()
                        }
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
