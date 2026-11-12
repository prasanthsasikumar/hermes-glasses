//
// MachineGuideViewModel.swift
//
// The machine guide: an engineer looks at a machine and asks; the glasses
// photograph it, the photo is matched to one of the imported manuals, and
// every question from then on is answered out loud from that manual.
// Built for glasses with NO display - nothing here needs a lens.
//
// Owned by the App struct, like Build Check, so the guide keeps running
// with the phone in a pocket. It borrows the mic, camera and speech from
// HermesSessionViewModel through `machineGuideClaimer` and the
// begin/finishExternalQuery pair; every decision (which machine, which
// manual a spoken name means, which pages) is pure and lives in
// MachineGuideLogic.swift. This file only wires.
//

import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class MachineGuideViewModel {
    /// Voice start ("help me assemble this"). The screen always works.
    static let voiceStartKey = "machine_guide_voice_start"

    var voiceStartEnabled: Bool = UserDefaults.standard.object(forKey: voiceStartKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(voiceStartEnabled, forKey: Self.voiceStartKey) }
    }

    // MARK: Observable state

    private(set) var manuals: [MachineManual] = []
    /// On = every utterance is a question for a manual, not for the brain.
    private(set) var isActive = false
    /// The machine in front of the engineer; nil until identified or named.
    private(set) var activeManualID: UUID?
    private(set) var importing = false
    /// A question is being identified or answered.
    private(set) var working = false
    var errorMessage: String?

    var activeManual: MachineManual? {
        activeManualID.flatMap { id in manuals.first { $0.id == id } }
    }

    // MARK: Collaborators

    let store = ManualStore()
    @ObservationIgnored private let guide = MachineGuide()
    @ObservationIgnored private let hermesVM: HermesSessionViewModel

    // MARK: Guide-scoped state (not observed)

    /// This machine's questions and answers. Reset on every machine change:
    /// "next" must never continue another machine's procedure.
    @ObservationIgnored private var history: [Turn] = []
    /// Asked before the machine was known; answered once it is named.
    @ObservationIgnored private var pendingQuestion: String?
    /// "Say its name" was spoken - a bare name is now an answer.
    @ObservationIgnored private var awaitingName = false
    @ObservationIgnored private var pagesCache: (id: UUID, pages: [String])?

    init(hermesVM: HermesSessionViewModel) {
        self.hermesVM = hermesVM
        hermesVM.machineGuideClaimer = { [weak self] text in self?.claim(text) ?? false }
        hermesVM.onMachineGuideSessionEnding = { [weak self] in self?.sessionEnded() }
        reload()
    }

    func reload() {
        manuals = store.all()
        if let id = activeManualID, !manuals.contains(where: { $0.id == id }) {
            activeManualID = nil
            history = []
        }
    }

    // MARK: - Manuals

    /// Reads the document on the phone, then asks the AI once for a name
    /// and a description to recognise the machine by. The manual is saved
    /// even when that call fails - a name and a picture can be added by hand.
    func importDocument(at url: URL) async -> MachineManual? {
        importing = true
        defer { importing = false }
        do {
            let imported = try await ManualImporter.read(fileAt: url)
            let scoped = url.startAccessingSecurityScopedResource()
            let data = try? Data(contentsOf: url)
            if scoped { url.stopAccessingSecurityScopedResource() }

            let stem = url.deletingPathExtension().lastPathComponent
            var manual = MachineManual(
                name: stem.isEmpty ? "Untitled machine" : stem,
                pageCount: imported.pages.count,
                characterCount: imported.pages.reduce(0) { $0 + $1.count })
            manual.sourceFilename = try data.map { try store.addSource($0, fileExtension: url.pathExtension) }
            try store.savePages(imported.pages, for: manual.id)
            if let cover = imported.cover, let jpeg = BuildCheckComposer.downscaledJPEG(cover) {
                manual.referencePhotoFilenames = [try store.addPhoto(jpeg)]
            }

            do {
                if let described = try await guide.profile(pages: imported.pages, filename: url.lastPathComponent) {
                    manual.profile = described.profile
                    if let name = described.name { manual.name = name }
                }
            } catch {
                errorMessage = "Imported, but the AI couldn't describe the machine (\(error.localizedDescription)). Add a description and a photo so it can be recognised."
            }
            store.save(manual)
            reload()
            return manual
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func save(_ manual: MachineManual) {
        var copy = manual
        copy.updatedAt = Date()
        store.save(copy)
        reload()
    }

    func delete(_ manual: MachineManual) {
        store.delete(id: manual.id)
        if pagesCache?.id == manual.id { pagesCache = nil }
        reload()
    }

    func referenceImage(_ filename: String) -> UIImage? {
        UIImage(contentsOfFile: store.photoURL(filename).path)
    }

    /// Returns the stored filename, or nil (with `errorMessage` set).
    func storeReferencePhoto(_ image: UIImage) -> String? {
        guard let jpeg = BuildCheckComposer.downscaledJPEG(image),
              let name = try? store.addPhoto(jpeg) else {
            errorMessage = "Couldn't save that photo."
            return nil
        }
        return name
    }

    /// A reference shot through whichever eye is active - the best
    /// reference is the machine seen the way the glasses will see it.
    func captureReferenceFromCamera() async -> UIImage? {
        guard await hermesVM.ensureVisionPermission(interactive: true),
              let data = try? await hermesVM.captureVisionPhoto() else {
            errorMessage = "Couldn't take a photo from the camera."
            return nil
        }
        return UIImage(data: data)
    }

    // MARK: - Start / end

    /// From the Manuals screen. `manual` skips identification ("I know
    /// what this is"); nil identifies on the first question.
    func start(with manual: MachineManual? = nil) async {
        guard !manuals.isEmpty else { errorMessage = "Import a manual first."; return }
        guard hermesVM.buildRunClaimer == nil else {
            errorMessage = "End the build check before starting the machine guide."
            return
        }
        let availability = MachineGuide.availability
        guard availability.ok else {
            errorMessage = "The machine guide needs an AI provider that can read images: \(availability.reason ?? "check Settings")."
            return
        }
        if hermesVM.connectionState != .disconnected, hermesVM.recordingOnlySession {
            errorMessage = "Stop the recording before starting the machine guide."
            return
        }
        if hermesVM.connectionState == .disconnected {
            await hermesVM.startSession()
            guard hermesVM.connectionState != .disconnected else {
                errorMessage = "Couldn't start listening."
                return
            }
        }
        activate()
        if let manual {
            select(manual.id)
            hermesVM.speakCue(MachineGuidePrompt.selected(manual.displayName), queued: true)
        } else {
            hermesVM.speakCue("Machine guide on. Look at the machine and ask your question.", queued: true)
        }
    }

    func end() {
        isActive = false
        resetMachine()
    }

    private func activate() {
        isActive = true
        resetMachine()
    }

    private func resetMachine() {
        activeManualID = nil
        history = []
        pendingQuestion = nil
        awaitingName = false
    }

    private func select(_ id: UUID) {
        if activeManualID != id { history = [] }
        activeManualID = id
        awaitingName = false
    }

    private func sessionEnded() {
        isActive = false
        working = false
        resetMachine()
    }

    // MARK: - The utterance stream

    /// Called by the session for every utterance that reaches the brain
    /// stage. True = the guide answers it.
    private func claim(_ text: String) -> Bool {
        let command = IntentDetector.machineGuideCommand(text)
        if !isActive {
            guard voiceStartEnabled, let command, command != .stop else { return false }
            if manuals.isEmpty {
                // A plain "help me assemble this" with no manuals is an
                // ordinary question for the brain; an explicit guide command
                // deserves to be told why nothing happened.
                guard command != .question else { return false }
                hermesVM.beginExternalQuery(text)
                hermesVM.finishExternalQuery(userText: text, reply: MachineGuidePrompt.noManuals, photo: nil)
                return true
            }
            activate()
        }
        // One at a time: the recognizer is suspended while an answer is
        // fetched, so this only catches Send-now and chip taps.
        guard !working else { return true }
        working = true
        hermesVM.beginExternalQuery(text)
        Task {
            await handle(text, command: command)
            working = false
        }
        return true
    }

    private func handle(_ text: String, command: MachineGuideCommand?) async {
        switch command {
        case .stop:
            end()
            say(MachineGuidePrompt.ended, for: text)
        case .start, .identify:
            resetMachine()
            await identify(userText: text, question: nil)
        case .question, nil:
            // "this is the K9 pump" - a deliberate switch, at any time.
            if let id = ManualNameMatcher.explicitSelection(text, manuals: manuals) {
                await chose(id, userText: text)
            } else if activeManualID == nil {
                if awaitingName, let id = ManualNameMatcher.answer(text, manuals: manuals) {
                    await chose(id, userText: text)
                } else {
                    await identify(userText: text, question: text)
                }
            } else {
                let photo = MachineGuidePrompt.wantsPhoto(text) ? await capturePhoto() : nil
                await answer(question: text, userText: text, prefix: "", photo: photo)
            }
        }
    }

    /// The engineer named the machine. A question asked before it was
    /// known is answered now; otherwise the choice is confirmed.
    private func chose(_ id: UUID, userText: String) async {
        select(id)
        let name = activeManual?.displayName ?? "that machine"
        if let question = pendingQuestion {
            pendingQuestion = nil
            await answer(question: question, userText: userText, prefix: "Okay, \(name). ", photo: nil)
        } else {
            say(MachineGuidePrompt.selected(name), for: userText)
        }
    }

    /// Photograph, match against the manuals, and either answer `question`
    /// from the matched manual or ask the engineer to name the machine.
    private func identify(userText: String, question: String?) async {
        let names = manuals.map(\.displayName)
        let availability = MachineGuide.availability
        guard availability.ok else {
            say("The machine guide can't see: \(availability.reason ?? "no image-capable AI provider is set up"). Fix that in Settings.", for: userText)
            return
        }
        guard let photo = await capturePhoto(), let now = UIImage(data: photo) else {
            askForName(MachineGuidePrompt.noPhoto(allNames: names), userText: userText, question: question, photo: nil)
            return
        }

        let candidates = MachineIdentifier.candidates(manuals)
        let references: [(label: String, image: UIImage)] = candidates.compactMap { candidate in
            guard let file = candidate.manual.referencePhotoFilenames.first,
                  let image = referenceImage(file) else { return nil }
            return ("\(candidate.label): \(candidate.manual.displayName.prefix(22))", image)
        }
        guard let sheet = MachineGuideComposer.sheet(now: now, references: references) else {
            askForName(MachineGuidePrompt.noPhoto(allNames: names), userText: userText, question: question, photo: nil)
            return
        }

        let outcome: MachineIdentifier.Outcome
        let identifyStarted = Date()
        defer { NSLog("[Hermes] machine guide: identify took \(Int(Date().timeIntervalSince(identifyStarted) * 1000)) ms") }
        do {
            outcome = try await guide.identify(
                sheetJPEG: sheet, candidates: candidates, hasReferenceTiles: !references.isEmpty)
        } catch {
            NSLog("[Hermes] machine guide identify failed: \(error.localizedDescription)")
            askForName("I couldn't check which machine this is. Say its name: \(MachineGuidePrompt.spokenList(names)).",
                       userText: userText, question: question, photo: photo)
            return
        }

        switch outcome {
        case .match(let id):
            select(id)
            let name = activeManual?.displayName ?? "this machine"
            if let question {
                // The photo that identified it also shows where they are.
                await answer(question: question, userText: userText, prefix: "This is \(name). ", photo: photo)
            } else {
                say(MachineGuidePrompt.identified(name), for: userText, photo: photo)
            }
        case .unsure(let guesses):
            let guessNames = guesses.compactMap { id in manuals.first { $0.id == id }?.displayName }
            askForName(MachineGuidePrompt.unsure(guesses: guessNames, allNames: names),
                       userText: userText, question: question, photo: photo)
        }
    }

    private func askForName(_ line: String, userText: String, question: String?, photo: Data?) {
        awaitingName = true
        pendingQuestion = question
        say(line, for: userText, photo: photo)
    }

    private func answer(question: String, userText: String, prefix: String, photo: Data?) async {
        guard let manual = activeManual else {
            say("I've lost track of which machine this is. Say which machine is this.", for: userText)
            return
        }
        let pages = pages(for: manual.id)
        guard pages.contains(where: { !$0.isEmpty }) else {
            say(prefix + "The manual for \(manual.displayName) has no readable text. Import it again on the Manuals screen.", for: userText)
            return
        }
        do {
            let started = Date()
            let reply = try await hermesVM.speakStreaming(prefix: prefix, guide.answer(
                question: question, machineName: manual.displayName, pages: pages,
                history: history, photoJPEG: photo))
            NSLog("[Hermes] machine guide: answer complete in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            // Only a whole answer, and only if the machine didn't change
            // while it was in flight.
            if !reply.failed, activeManualID == manual.id {
                history.append(Turn(role: "user", text: question))
                history.append(Turn(role: "assistant", text: reply.body))
                if history.count > MachineGuidePrompt.maxHistoryTurns {
                    history.removeFirst(history.count - MachineGuidePrompt.maxHistoryTurns)
                }
            }
            hermesVM.finishExternalQuery(userText: userText, streamed: reply, photo: photo)
        } catch {
            // Spoken, not just shown: the engineer isn't looking at a phone.
            say(prefix + "I couldn't get an answer from the manual. \(error.localizedDescription) Ask again.", for: userText)
        }
    }

    // MARK: - Plumbing

    private func say(_ reply: String, for userText: String, photo: Data? = nil) {
        hermesVM.finishExternalQuery(userText: userText, reply: reply, photo: photo)
    }

    private func capturePhoto() async -> Data? {
        guard hermesVM.hasVisionSource,
              await hermesVM.ensureVisionPermission(interactive: false) else { return nil }
        return try? await hermesVM.captureVisionPhoto()
    }

    private func pages(for id: UUID) -> [String] {
        if let cached = pagesCache, cached.id == id { return cached.pages }
        let pages = store.pages(for: id)
        pagesCache = (id, pages)
        return pages
    }
}
