//
// MachineGuideLogic.swift
//
// Everything the machine guide decides without hardware or a network:
// which machine a model's reply named and whether to believe it, which
// manual a spoken name means, which pages of a long manual go with a
// question, and the words of every prompt. Foundation only; tested in
// tests/manuals.
//

import Foundation

// MARK: - Which machine is this?

enum MachineIdentifier {
    /// Below this the guide ASKS instead of assuming. A wrong manual read
    /// out with confidence is the failure that matters here - someone
    /// torques a bolt to another machine's figure - so an unsure answer
    /// costs one spoken name and a wrong one costs the assembly.
    /// PROVISIONAL until measured on real machines through the glasses.
    static let acceptConfidence = 0.6

    /// One reference tile each has to stay legible on a single sheet.
    static let maxCandidates = 12

    struct Candidate: Equatable {
        /// "A", "B", … - what the model answers with. Letters, not UUIDs:
        /// a model copies one character reliably and 36 less so.
        let label: String
        let manual: MachineManual
    }

    enum Outcome: Equatable {
        case match(UUID)
        /// Not confident. Best guesses first; may be empty.
        case unsure([UUID])
    }

    static func candidates(_ manuals: [MachineManual]) -> [Candidate] {
        manuals.prefix(maxCandidates).enumerated().map { index, manual in
            Candidate(label: String(UnicodeScalar(UInt8(65 + index))), manual: manual)
        }
    }

    static let systemPrompt = """
        You identify industrial machines and engines for an assembly engineer. \
        You are given a photo of what the engineer is looking at and a short \
        list of known machines. Decide which known machine is in the photo. \
        Text on the machine itself - a nameplate, model number, serial label, \
        part number - is the strongest evidence; overall shape, colour and \
        distinctive parts come next. A machine that is only partly assembled \
        still counts. If the photo shows no machine, or one that is not on \
        the list, answer "none". Never guess to be helpful: a wrong answer \
        sends the engineer the wrong assembly manual. Reply with ONLY a JSON \
        object.
        """

    static func userPrompt(candidates: [Candidate], hasReferenceTiles: Bool) -> String {
        var lines: [String] = []
        if hasReferenceTiles {
            lines.append("""
                The large panel labelled NOW is what the engineer sees. The smaller \
                labelled tiles under it are reference pictures of known machines \
                (a photo of the machine, or the cover page of its manual).
                """)
        } else {
            lines.append("The photo is what the engineer sees right now.")
        }
        lines.append("")
        lines.append("Known machines:")
        for c in candidates {
            let profile = c.manual.profile.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append("\(c.label): \(c.manual.displayName)" + (profile.isEmpty ? "" : " - \(profile)"))
        }
        lines.append("")
        lines.append("""
            Reply with ONLY this JSON: {"machine": "<letter or none>", \
            "confidence": <0.0-1.0>, "runner_up": "<letter or none>", \
            "evidence": "<what you saw, under 20 words>"}
            """)
        return lines.joined(separator: "\n")
    }

    static func outcome(fromReply reply: String, candidates: [Candidate]) -> Outcome {
        guard let json = BuildCheckJSON.object(in: reply) else { return .unsure([]) }
        let best = resolve(json["machine"], candidates)
        let runnerUp = resolve(json["runner_up"], candidates)
        let confidence = number(json["confidence"]) ?? 0
        if let best, confidence >= acceptConfidence { return .match(best) }
        var guesses: [UUID] = []
        for id in [best, runnerUp] {
            if let id, !guesses.contains(id) { guesses.append(id) }
        }
        return .unsure(guesses)
    }

    private static func resolve(_ value: Any?, _ candidates: [Candidate]) -> UUID? {
        guard let raw = value as? String else { return nil }
        let text = raw.trimmingCharacters(in: CharacterSet(charactersIn: " .:\"'"))
        if let byLabel = candidates.first(where: { $0.label.caseInsensitiveCompare(text) == .orderedSame }) {
            return byLabel.manual.id
        }
        // A model that answers with the name instead of the letter.
        return candidates.first {
            $0.manual.displayName.caseInsensitiveCompare(text) == .orderedSame
        }?.manual.id
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}

// MARK: - Which manual did they say?

/// The way out when the camera can't tell: the engineer says the name.
enum ManualNameMatcher {
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ").map(String.init)
    }

    private static let fillers: Set<String> = ["hey", "ok", "okay", "hermes", "please"]
    private static let leadIns: [[String]] = [
        ["this", "is"], ["it", "is"], ["it", "s"], ["its"], ["use"],
        ["switch", "to"], ["i", "m", "working", "on"], ["i", "am", "working", "on"],
        ["we", "re", "working", "on"], ["we", "are", "working", "on"], ["working", "on"],
    ]

    /// "this is the K9 pump", "use machine B" - a deliberate switch, safe to
    /// honour at any time because the sentence is nothing but the name.
    static func explicitSelection(_ text: String, manuals: [MachineManual]) -> UUID? {
        var words = tokens(text)
        while let first = words.first, fillers.contains(first) { words.removeFirst() }
        guard let lead = leadIns.first(where: { words.starts(with: $0) }) else { return nil }
        var rest = Array(words.dropFirst(lead.count))
        if rest.first == "the" { rest.removeFirst() }
        if rest.last == "manual" { rest.removeLast() }
        guard !rest.isEmpty else { return nil }
        let hits = manuals.filter { nameTokens($0) == rest }
        return hits.count == 1 ? hits[0].id : nil
    }

    /// Looser, for the moment right after "say its name": the whole name
    /// anywhere in the utterance, or a short reply whose only distinguishing
    /// word belongs to one manual ("B", "the pump one").
    static func answer(_ text: String, manuals: [MachineManual]) -> UUID? {
        if let explicit = explicitSelection(text, manuals: manuals) { return explicit }
        let words = tokens(text)
        guard !words.isEmpty else { return nil }

        let containing = manuals.filter { contains(words, nameTokens($0)) }
        if let longest = containing.map({ nameTokens($0).count }).max() {
            let top = containing.filter { nameTokens($0).count == longest }
            return top.count == 1 ? top[0].id : nil
        }

        guard words.count <= 4 else { return nil }
        var owners = Set<UUID>()
        for word in words {
            let having = manuals.filter { nameTokens($0).contains(word) }
            if having.count == 1 { owners.insert(having[0].id) }
        }
        return owners.count == 1 ? owners.first : nil
    }

    private static func nameTokens(_ manual: MachineManual) -> [String] {
        var words = tokens(manual.name)
        if words.first == "the" { words.removeFirst() }
        return words
    }

    private static func contains(_ haystack: [String], _ needle: [String]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        for start in 0...(haystack.count - needle.count)
        where Array(haystack[start..<start + needle.count]) == needle {
            return true
        }
        return false
    }
}

// MARK: - Which pages go with this question?

/// A manual that fits is sent whole (and cached by providers that cache).
/// One that doesn't is cut to the pages that share words with the question,
/// plus the page after each - steps run over page breaks.
enum ManualExcerpt {
    /// Characters of manual per question, roughly 30k tokens.
    static let defaultBudget = 120_000

    struct Context: Equatable {
        let text: String
        /// 1-based, ascending.
        let includedPages: [Int]
        let totalPages: Int
        var isComplete: Bool { includedPages.count == totalPages }
    }

    private static let stopwords: Set<String> = [
        "the", "and", "for", "that", "this", "with", "what", "how", "does",
        "from", "have", "are", "was", "you", "your", "can", "next", "now",
        "then", "which", "where", "when", "into", "about", "should", "would",
        "there", "here", "its", "it's", "say", "tell", "step",
    ]

    static func context(pages: [String], query: String, budget: Int = defaultBudget) -> Context {
        let rendered: [(page: Int, text: String)] = pages.enumerated().compactMap { index, raw in
            let body = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? nil : (index + 1, "[Page \(index + 1)]\n\(body)\n\n")
        }
        let total = rendered.count
        guard total > 0 else { return Context(text: "", includedPages: [], totalPages: 0) }
        if rendered.reduce(0, { $0 + $1.text.count }) <= budget {
            return Context(text: rendered.map(\.text).joined(), includedPages: rendered.map(\.page), totalPages: total)
        }

        let terms = Set(ManualNameMatcher.tokens(query).filter { $0.count >= 3 && !stopwords.contains($0) })
        var scores = [Int](repeating: 0, count: total)
        if !terms.isEmpty {
            for (i, entry) in rendered.enumerated() {
                var counts: [String: Int] = [:]
                for word in ManualNameMatcher.tokens(entry.text) where terms.contains(word) {
                    counts[word, default: 0] += 1
                }
                // Capped per term: a parts table that says "bolt" 80 times
                // must not outrank the page that describes fitting it.
                scores[i] = counts.values.reduce(0) { $0 + min($1, 5) }
            }
        }

        var chosen = Set<Int>()
        var used = 0
        func take(_ i: Int) {
            guard i < total, !chosen.contains(i), used + rendered[i].text.count <= budget else { return }
            chosen.insert(i)
            used += rendered[i].text.count
        }

        // The opening page names the machine and usually carries the
        // general warnings; keep it when it is cheap.
        if rendered[0].text.count <= budget / 4 { take(0) }

        let ranked = scores.indices.filter { scores[$0] > 0 }
            .sorted { scores[$0] != scores[$1] ? scores[$0] > scores[$1] : $0 < $1 }
        if ranked.isEmpty {
            for i in 0..<total { take(i) }
        } else {
            for i in ranked { take(i); take(i + 1) }
        }

        if chosen.isEmpty {
            // Even the best page is bigger than the budget: send its start.
            let i = ranked.first ?? 0
            return Context(text: String(rendered[i].text.prefix(budget)),
                           includedPages: [rendered[i].page], totalPages: total)
        }
        let order = chosen.sorted()
        return Context(text: order.map { rendered[$0].text }.joined(),
                       includedPages: order.map { rendered[$0].page }, totalPages: total)
    }
}

// MARK: - Prompts and spoken lines

enum MachineGuidePrompt {
    /// How much of a manual the import-time profile call reads.
    static let profileSampleCharacters = 12_000
    static let maxHistoryTurns = 16

    static func system(machineName: String, context: ManualExcerpt.Context) -> String {
        let coverage = context.isComplete
            ? "The full manual follows."
            : """
              Only the pages of the manual most relevant to the question follow \
              (\(context.includedPages.count) of \(context.totalPages)). If the answer \
              is not in them, say you can't find it in the manual and ask the engineer \
              to name the section or step.
              """
        return """
            You are an assembly guide speaking through an engineer's smart glasses. \
            The glasses have no screen: everything you say is heard, not read. The \
            engineer is assembling: \(machineName).

            Rules:
            - Answer ONLY from the manual below. If it does not cover the question, \
            say so plainly. Never guess a torque, part number, sequence, clearance \
            or safety step.
            - One step at a time. Give the current step in one to three short \
            sentences, then stop; the engineer will say "next" for the following one.
            - Say numbers and units exactly as the manual gives them, and mention \
            the step number or page when it helps the engineer find it.
            - If the manual attaches a warning or caution to a step, say it first.
            - Plain speech only: no markdown, no bullet points, no lettered or \
            numbered option lists.
            - A photo, when attached, shows what the engineer is looking at now. \
            Use it to work out where they are and say if something looks different \
            from the manual - but the manual is the authority, not the photo.

            \(coverage)

            MANUAL
            \(context.text)
            """
    }

    private static let photoWords: Set<String> = [
        "this", "that", "these", "those", "here", "look", "looks", "looking",
        "see", "right", "correct", "wrong", "where", "which", "photo", "picture",
    ]

    /// A question that points at something ("is this right", "where does
    /// this go") gets a fresh photo; "what's the torque for the head bolts"
    /// doesn't need the second it costs.
    static func wantsPhoto(_ text: String) -> Bool {
        ManualNameMatcher.tokens(text).contains { photoWords.contains($0) }
    }

    // MARK: Import profile

    static let profileSystemPrompt = """
        You read the opening of a machine's assembly manual and describe the \
        machine so that someone could recognise it on sight. Reply with ONLY a \
        JSON object.
        """

    static func profileUserPrompt(document: String, filename: String) -> String {
        """
        File name: \(filename)

        Reply with ONLY this JSON: {"name": "<the machine's name and model as a \
        mechanic would say it, under 6 words>", "profile": "<two or three \
        sentences: what kind of machine it is, model or part numbers that would \
        be printed on it, and the visible features that set it apart - size, \
        shape, colour, distinctive parts>"}

        Use only what the manual says. If it gives no visual details, describe \
        what kind of machine it is and leave the rest out.

        MANUAL (opening):
        \(String(document.prefix(profileSampleCharacters)))
        """
    }

    static func profile(fromAIReply reply: String) -> (name: String?, profile: String)? {
        guard let json = BuildCheckJSON.object(in: reply) else { return nil }
        let name = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = (json["profile"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if (name ?? "").isEmpty, profile.isEmpty { return nil }
        return ((name ?? "").isEmpty ? nil : name, profile)
    }

    // MARK: Spoken lines

    /// "A, B or C" - at most five names, so a long shelf of manuals isn't
    /// read out in full.
    static func spokenList(_ names: [String]) -> String {
        let shown = Array(names.prefix(5))
        switch shown.count {
        case 0: return ""
        case 1: return shown[0]
        default: return shown.dropLast().joined(separator: ", ") + " or " + shown[shown.count - 1]
        }
    }

    static func identified(_ name: String) -> String {
        "This is \(name). Ask me anything about assembling it, or say first step."
    }

    static func selected(_ name: String) -> String {
        "Okay, \(name). Ask me anything about assembling it, or say first step."
    }

    static func unsure(guesses: [String], allNames: [String]) -> String {
        if !guesses.isEmpty {
            return "I'm not sure which machine this is. It might be \(spokenList(guesses)). Say its name, or look at its nameplate and ask again."
        }
        return "I don't recognise this machine. I have manuals for \(spokenList(allNames)). Say its name, or look at its nameplate and ask again."
    }

    static func noPhoto(allNames: [String]) -> String {
        "I couldn't get a photo. Say which machine it is: \(spokenList(allNames))."
    }

    static let ended = "Machine guide ended."
    static let noManuals = "There are no machine manuals yet. Add one on the Manuals screen."
}
