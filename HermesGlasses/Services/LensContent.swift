//
// LensContent.swift
//
// What is on the lens right now, as a value. The glasses render it through
// the Meta SDK's own view DSL (HermesDisplayScreens); phone mode renders
// the SAME value in SwiftUI (SimulatedLensView). Neither renderer knows
// the other exists.
//
// Foundation only - no MWDATDisplay, no SwiftUI - so the text derivation
// below unit-tests standalone with swiftc, like DwellTracker.
//

import Foundation

enum LensContent: Equatable {
    case blank
    case listening(partial: String)
    case thinking(query: String)
    case photoCaptured
    /// A person was snapped during a conversation capture. `name` is nil
    /// when no badge could be read - most of the time, at glasses range.
    case personSighted(name: String?, subtitle: String?)
    /// Lookup found someone online: their badge name and what the web says
    /// about them. `info` is the searched summary, already trimmed to a
    /// couple of sentences.
    case personLookup(name: String, info: String)
    /// Translate named a thing: the word in the chosen language, a
    /// romanisation when the script is not Latin, and the English.
    /// `language` is the language's DISPLAY name - a plain string, so this
    /// file still compiles alone in tests/lens-content.
    case translation(word: String, romanized: String?, english: String, language: String)
    case reply(text: String, speaking: Bool, choices: [ReplyChoice] = [])
    case definition(text: String, imageURL: String?)
    case navigation(title: String, step: String, eta: String, mapURL: String?, mode: TransportMode)
    case encounterPrompt
    case recording
    case encounterSaved(note: String)
    case newConversation
    /// Build Check: the current step, or an open flag in place of it.
    case buildCheck(step: Int, total: Int, text: String, flag: String?)

    /// Nothing to draw - the simulated lens shows its empty frame.
    var isBlank: Bool { self == .blank }

    /// Small all-caps line above the body, or nil when the body speaks for
    /// itself (a reply has no label on the real lens either).
    var label: String? {
        switch self {
        case .blank: return nil
        case .listening: return "LISTENING"
        case .thinking: return nil
        case .photoCaptured: return "PHOTO"
        case .personSighted: return "PERSON"
        // The name is the label so the body is free for the summary.
        case .personLookup(let name, _): return name.uppercased()
        case .translation(_, _, _, let language): return language.uppercased()
        case .reply: return nil
        case .definition: return nil
        case .navigation: return "NAVIGATION"
        case .encounterPrompt: return "WHO IS THIS?"
        case .recording: return "RECORDING"
        case .encounterSaved: return "SAVED"
        case .newConversation: return "NEW CHAT"
        case .buildCheck(let step, let total, _, _): return "STEP \(step)/\(total)"
        }
    }

    /// The main line. Empty string means "draw nothing".
    var body: String {
        switch self {
        case .blank:
            return ""
        case .listening(let partial):
            return partial
        case .thinking(let query):
            return query
        case .photoCaptured:
            return "Photo captured"
        case .personSighted(let name, _):
            return name ?? "Photo captured"
        case .personLookup(_, let info):
            return info
        case .translation(let word, _, _, _):
            return word
        case .reply(let text, _, _):
            return text
        case .definition(let text, _):
            return text
        case .navigation(_, let step, _, _, _):
            return step
        case .encounterPrompt:
            return "Say a note - name, where you met, follow-up"
        case .recording:
            return "Saving this conversation"
        case .encounterSaved(let note):
            return note.isEmpty ? "Note saved" : note
        case .newConversation:
            return "New conversation"
        case .buildCheck(_, _, let text, let flag):
            return flag ?? text
        }
    }

    /// Monospaced status line under the body: what Hermes is doing, and any
    /// running figures. Nil when there is nothing to add.
    var statusLine: String? {
        switch self {
        case .blank, .photoCaptured, .encounterSaved, .newConversation:
            return nil
        case .personSighted(_, let subtitle):
            return subtitle
        case .personLookup:
            return "web lookup"
        case .translation(_, let romanized, let english, _):
            return [romanized, english].compactMap { $0 }.joined(separator: " · ")
        case .listening:
            return "listening"
        case .thinking:
            return "thinking…"
        case .reply(_, let speaking, let choices):
            if !choices.isEmpty { return "\(choices.count) options - tap one" }
            return speaking ? "speaking" : nil
        case .definition:
            return nil
        case .navigation(let title, _, let eta, _, let mode):
            return "\(mode == .driving ? "driving" : "walking") · \(eta) to \(title)"
        case .encounterPrompt:
            return "waiting for a note"
        case .recording:
            return "say \"stop recording\" to finish"
        case .buildCheck(_, _, _, let flag):
            return flag == nil ? "say \"step done\" when finished" : "confirmed · ignore · fixed"
        }
    }

    /// A remote image to show above the body (Mapbox map, Wikipedia lead
    /// image). Nil for text-only screens.
    var imageURL: String? {
        switch self {
        case .definition(_, let url): return url
        case .navigation(_, _, _, let url, _): return url
        default: return nil
        }
    }

    /// True while the lens is showing something the user is expected to
    /// keep looking at, so the simulated lens keeps a live dot lit.
    var isLive: Bool {
        switch self {
        case .blank, .photoCaptured, .encounterSaved, .newConversation,
             .personSighted, .personLookup, .translation:
            return false
        case .listening, .thinking, .reply, .definition, .navigation,
             .encounterPrompt, .recording, .buildCheck:
            return true
        }
    }
}
