//
// SentenceChunker.swift
//
// Cuts a reply into speakable pieces AS IT ARRIVES, so the first sentence
// can be on its way to the voice while the model is still writing the
// second. Time-to-first-word is what makes a voice assistant feel fast;
// total time barely matters once it is talking.
//
// Rules: a piece ends at . ! ? (or a line break) followed by whitespace -
// so "2.5 mm" and "v1.2" never split. The FIRST piece is released as soon
// as it is a sentence, however short ("Okay." buys a second of thinking
// time). Later pieces are grouped up to `targetLength`, because every
// piece is a separate voice request and a new intonation contour: many
// tiny ones sound choppy. Foundation only; tested in tests/voice.
//

import Foundation

struct SentenceChunker {
    /// Later pieces are held until they reach this many characters (or the
    /// reply ends).
    static let targetLength = 140
    /// A run with no sentence end is cut at a clause or word break here, so
    /// a long unpunctuated answer still starts speaking.
    static let hardLimit = 320

    private var buffer = ""
    private var emittedFirst = false

    /// Add text; returns the pieces that are now complete, in order.
    mutating func feed(_ text: String) -> [String] {
        buffer += text
        var pieces: [String] = []
        while let piece = nextPiece() { pieces.append(piece) }
        return pieces
    }

    /// The reply is over: whatever is left, if anything.
    mutating func flush() -> [String] {
        let rest = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return rest.isEmpty ? [] : [rest]
    }

    /// One whole reply, cut the same way (for text that didn't stream).
    static func pieces(of text: String) -> [String] {
        var chunker = SentenceChunker()
        return chunker.feed(text) + chunker.flush()
    }

    private mutating func nextPiece() -> String? {
        let minimum = emittedFirst ? Self.targetLength : 1
        var cut: String.Index?
        var index = buffer.startIndex
        var length = 0
        while index < buffer.endIndex {
            let ch = buffer[index]
            let next = buffer.index(after: index)
            length += 1
            let isEnd = ch == "\n"
                || ((ch == "." || ch == "!" || ch == "?")
                    && next < buffer.endIndex && buffer[next].isWhitespace)
            if isEnd, length >= minimum {
                cut = next
                break
            }
            index = next
        }

        if cut == nil, buffer.count > Self.hardLimit {
            // No sentence end in sight: break at the last clause mark, else
            // the last space, inside the limit.
            let window = buffer.prefix(Self.hardLimit)
            if let mark = window.lastIndex(where: { $0 == "," || $0 == ";" || $0 == ":" }) {
                cut = buffer.index(after: mark)
            } else if let space = window.lastIndex(of: " ") {
                cut = space
            } else {
                cut = window.endIndex
            }
        }

        guard let cut else { return nil }
        let piece = buffer[..<cut].trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = String(buffer[cut...])
        guard !piece.isEmpty else { return nextPiece() }
        emittedFirst = true
        return piece
    }
}
