//
// HermesDisplayManager.swift
//
// Attaches the Display capability to the shared voice DeviceSession and
// renders HUD screens. Strictly best-effort: every failure is logged and
// swallowed - the voice loop must never notice the display.
//

import Foundation
import MWDATCore
import MWDATDisplay
import os

enum DisplayHUDStatus: Equatable {
    case off                    // toggle disabled or no session
    case connecting
    case connected
    case unavailable(String)    // attach failed / update needed / dropped
}

@MainActor
final class HermesDisplayManager {
    private let logger = Logger(
        subsystem: "com.flowsxr.hermesglasses", category: "display"
    )

    private(set) var status: DisplayHUDStatus = .off {
        didSet {
            if status != oldValue { onStatusChanged?(status) }
        }
    }

    var onStatusChanged: ((DisplayHUDStatus) -> Void)?
    var onDebug: ((String) -> Void)?
    /// On-lens button callbacks (invoked on the main actor)
    var onStop: (() -> Void)?
    var onRepeat: (() -> Void)?
    var onNewChat: (() -> Void)?
    var onStopNavigation: (() -> Void)?

    private var display: Display?
    private var stateListenerToken: AnyListenerToken?
    private var stateTask: Task<Void, Never>?
    private var stateContinuation: AsyncStream<DisplayState>.Continuation?
    /// Latest view queued while the capability is still attaching
    private var pendingView: FlexBox?
    /// Serialized send pipeline: newest queued view wins, one send in
    /// flight at a time (BLE sends can complete out of order otherwise)
    private var queuedView: FlexBox?
    private var sendTask: Task<Void, Never>?
    private var dwellTask: Task<Void, Never>?
    private var throttle = DisplaySendThrottle()
    private var lastReplyText: String = ""

    // MARK: - Lifecycle

    /// Attach the display capability on the shared voice session.
    func start(session: DeviceSession) {
        guard display == nil else { return }
        status = .connecting

        do {
            let capability = try session.addDisplay()

            let (stream, continuation) = AsyncStream.makeStream(of: DisplayState.self)
            stateContinuation = continuation
            stateListenerToken = capability.statePublisher.listen { state in
                continuation.yield(state)
            }

            stateTask = Task { [weak self] in
                for await state in stream {
                    guard let self, !Task.isCancelled else { return }
                    switch state {
                    case .starting, .stopping:
                        break
                    case .started:
                        self.status = .connected
                        self.debug("Display attached")
                        if let view = self.pendingView {
                            self.pendingView = nil
                            self.transmit(view)
                        }
                    case .stopped:
                        // Mid-session drop unless stop() already ran
                        if self.status != .off {
                            self.status = .unavailable("Display stopped")
                        }
                        self.cleanup()
                        return
                    }
                }
            }

            capability.start()
            display = capability
        } catch {
            status = .unavailable(error.localizedDescription)
            debug("Display attach failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        cancelDwell()
        pendingView = nil
        lastReplyText = ""
        status = .off
        display?.stop()
        // Tear down synchronously - waiting for the async .stopped event
        // leaves `display` non-nil, and a quick start() would then bail on
        // its guard and never re-attach. cleanup() is idempotent, so the
        // late .stopped event (stream already finished) is harmless.
        cleanup()
    }

    private func cleanup() {
        stateListenerToken = nil
        stateContinuation?.finish()
        stateContinuation = nil
        stateTask?.cancel()
        stateTask = nil
        display = nil
        queuedView = nil
    }

    // MARK: - Screens

    func showListening(partial: String) {
        guard throttle.shouldSend() else { return }
        cancelDwell()
        send(HermesDisplayScreens.listening(partial: partial))
    }

    func showThinking(query: String) {
        cancelDwell()
        send(HermesDisplayScreens.thinking(query: query))
    }

    func showPhotoCaptured() {
        cancelDwell()
        send(HermesDisplayScreens.photoCaptured())
    }

    /// speaking=true keeps the card up (Stop button shown, no dwell);
    /// dwellSeconds non-nil blanks the lens after that many seconds.
    func showReply(text: String, speaking: Bool, dwellSeconds: Double?) {
        cancelDwell()
        lastReplyText = text
        send(HermesDisplayScreens.reply(
            text: text,
            speaking: speaking,
            onStop: { [weak self] in
                Task { @MainActor in self?.onStop?() }
            },
            onRepeat: { [weak self] in
                Task { @MainActor in self?.onRepeat?() }
            },
            onNewChat: { [weak self] in
                Task { @MainActor in self?.onNewChat?() }
            }
        ))
        if let dwellSeconds {
            scheduleDwell(seconds: dwellSeconds)
        }
    }

    /// TTS ended or was interrupted: re-render without Stop, start the
    /// spoken dwell, then blank.
    func replySpeakingFinished() {
        guard !lastReplyText.isEmpty else { return }
        showReply(
            text: lastReplyText,
            speaking: false,
            dwellSeconds: HermesDisplayLogic.spokenDwellSeconds
        )
    }

    /// Active navigation frame. Owns the lens until stopped; no dwell.
    func showNavigation(mapURL: String?, title: String, step: String, eta: String) {
        cancelDwell()
        lastReplyText = ""
        send(HermesDisplayScreens.navigation(
            mapURL: mapURL,
            title: title,
            step: step,
            eta: eta,
            onStop: { [weak self] in
                Task { @MainActor in self?.onStopNavigation?() }
            }
        ))
    }

    /// Definition reply: picture + text. Dwell like a normal spoken reply.
    func showDefinition(text: String, imageURL: String?) {
        cancelDwell()
        lastReplyText = text
        send(HermesDisplayScreens.definition(text: text, imageURL: imageURL))
        scheduleDwell(seconds: HermesDisplayLogic.spokenDwellSeconds)
    }

    func showNewConversationFlash() {
        cancelDwell()
        lastReplyText = ""
        send(HermesDisplayScreens.newConversation())
        scheduleDwell(seconds: 2)
    }

    func clear() {
        cancelDwell()
        lastReplyText = ""
        send(HermesDisplayScreens.blank())
    }

    /// Test panel: throws so the button can show WHY it failed.
    func sendTest() async throws {
        guard let display, status == .connected else {
            throw NSError(
                domain: "HermesDisplay", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Display not attached (status: \(status))"]
            )
        }
        try await display.send(HermesDisplayScreens.testScreen())
    }

    // MARK: - Plumbing

    private func send(_ view: FlexBox) {
        switch status {
        case .connected:
            transmit(view)
        case .connecting:
            pendingView = view  // latest wins; flushed on .started
        case .off, .unavailable:
            break
        }
    }

    private func transmit(_ view: FlexBox) {
        guard display != nil else { return }
        queuedView = view
        guard sendTask == nil else { return }  // drain loop already running
        sendTask = Task { [weak self] in
            while let self, let next = self.queuedView {
                self.queuedView = nil
                guard let display = self.display else { break }
                do {
                    try await display.send(next)
                } catch {
                    self.debug("Display send failed: \(error.localizedDescription)")
                }
            }
            self?.sendTask = nil
        }
    }

    private func scheduleDwell(seconds: Double) {
        dwellTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.clear()
        }
    }

    private func cancelDwell() {
        dwellTask?.cancel()
        dwellTask = nil
    }

    private func debug(_ message: String) {
        logger.info("\(message, privacy: .public)")
        onDebug?(message)
    }
}
