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
    private let captureLock = OSAllocatedUnfairLock(initialState: false)

    private var deviceSession: DeviceSession?
    private var stream: MWDATCamera.Stream?

    func configure(session: DeviceSession) {
        if let existing = stream {
            existing.stop()
            stream = nil
        }
        deviceSession = session
    }

    func reset() {
        stream?.stop()
        stream = nil
        deviceSession = nil
    }

    /// Capture a single JPEG from the glasses camera.
    func capturePhoto() async throws -> Data {
        let alreadyInFlight = captureLock.withLock { inFlight -> Bool in
            if inFlight { return true }
            inFlight = true
            return false
        }
        guard !alreadyInFlight else {
            throw HermesCameraError.captureInProgress
        }
        defer { captureLock.withLock { $0 = false } }

        guard let session = deviceSession else {
            throw HermesCameraError.noSession
        }

        let stream: MWDATCamera.Stream
        if let existing = self.stream {
            stream = existing
        } else {
            guard let created = try session.addStream() else {
                throw HermesCameraError.streamUnavailable
            }
            self.stream = created
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
