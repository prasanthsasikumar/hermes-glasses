//
// HermesDisplayScreens.swift
//
// Pure screen builders for the glasses display HUD: state → view tree.
// No session state lives here.
//

import MWDATDisplay

enum HermesDisplayScreens {
    /// User is speaking - show the partial transcript.
    static func listening(partial: String) -> FlexBox {
        FlexBox(direction: .column, spacing: 8) {
            Text("Listening", style: .meta, color: .secondary)
            Text(partial, style: .body)
        }
        .padding(24)
    }

    /// Query submitted, waiting for the brain.
    static func thinking(query: String) -> FlexBox {
        FlexBox(direction: .column, spacing: 8) {
            Text(query, style: .body, color: .secondary)
            Text("Thinking…", style: .meta, color: .secondary)
        }
        .padding(24)
    }

    /// Brief flash while a glasses photo is being captured.
    static func photoCaptured() -> FlexBox {
        FlexBox(direction: .row, spacing: 12, crossAlignment: .center) {
            Icon(name: .fourCornerFrame)
            Text("Photo captured", style: .body)
        }
        .padding(24)
    }

    /// A person snapped during a conversation capture. Shows their name
    /// when a badge could be read; otherwise it is the plain photo flash.
    static func personSighted(name: String?, subtitle: String?) -> FlexBox {
        FlexBox(direction: .column, spacing: 6, crossAlignment: .start) {
            Text(name ?? "Photo captured", style: .body)
            for line in [subtitle].compactMap({ $0 }) {
                Text(line, style: .meta, color: .secondary)
            }
        }
        .padding(24)
    }

    /// Lookup found someone: their badge name over what the web says about
    /// them. A card, not a live state - it dwells away on its own.
    static func personLookup(name: String, info: String) -> FlexBox {
        FlexBox(direction: .column, spacing: 8) {
            Text(name, style: .heading)
            FlexBox(direction: .column) {
                Text(info, style: .body)
            }
            .padding(16)
            .background(.card)
        }
        .padding(24)
    }

    /// Translate's card: the word large, with its reading and the English
    /// underneath. A card, not a live state - it dwells away on its own.
    static func translation(
        word: String, romanized: String?, english: String, language: String
    ) -> FlexBox {
        let detail = [romanized, english].compactMap { $0 }.joined(separator: " · ")
        return FlexBox(direction: .column, spacing: 8) {
            Text(language.uppercased(), style: .body)
            FlexBox(direction: .column, spacing: 4) {
                Text(word, style: .heading)
                Text(detail, style: .body)
            }
            .padding(16)
            .background(.card)
        }
        .padding(24)
    }

    /// The reply card. Stop appears only while TTS is playing.
    /// ComponentBuilder has no buildOptional, so conditional buttons are
    /// prebuilt as an array and emitted with a for-loop (buildArray).
    static func reply(
        text: String,
        speaking: Bool,
        choices: [ReplyChoice] = [],
        onStop: @escaping @Sendable () -> Void,
        onRepeat: @escaping @Sendable () -> Void,
        onNewChat: @escaping @Sendable () -> Void,
        onChoose: @escaping @Sendable (ReplyChoice) -> Void = { _ in }
    ) -> FlexBox {
        var buttons: [Button] = []

        // When the reply offered options, THOSE are the useful controls -
        // answering by tapping beats reading the letters back aloud. Stop
        // stays available while speech is playing; Repeat/New chat step
        // aside rather than crowd the lens.
        if !choices.isEmpty {
            if speaking {
                buttons.append(Button(label: "Stop", style: .secondary, onClick: onStop))
            }
            for choice in choices {
                buttons.append(Button(
                    label: choice.shortLabel,
                    style: .primary,
                    onClick: { onChoose(choice) }
                ))
            }
            return FlexBox(direction: .column, spacing: 12) {
                FlexBox(direction: .column) {
                    Text(text, style: .body)
                }
                .padding(24)
                .background(.card)

                FlexBox(
                    direction: .row, spacing: 8,
                    alignment: .center, crossAlignment: .center, wrap: true
                ) {
                    for button in buttons {
                        button
                    }
                }
            }
        }

        if speaking {
            buttons.append(Button(label: "Stop", style: .primary, onClick: onStop))
        }
        buttons.append(Button(label: "Repeat", style: .secondary, onClick: onRepeat))
        buttons.append(Button(label: "New chat", style: .secondary, onClick: onNewChat))

        return FlexBox(direction: .column, spacing: 12) {
            FlexBox(direction: .column) {
                Text(text, style: .body)
            }
            .padding(24)
            .background(.card)

            FlexBox(
                direction: .row, spacing: 8,
                alignment: .center, crossAlignment: .center, wrap: true
            ) {
                for button in buttons {
                    button
                }
            }
        }
    }

    /// Confirmation flash after New chat.
    static func newConversation() -> FlexBox {
        FlexBox(direction: .row, spacing: 12, crossAlignment: .center) {
            Icon(name: .checkmarkCircle)
            Text("New conversation", style: .body)
        }
        .padding(24)
    }

    /// Active navigation: map image (when a URL is available) over the
    /// destination title, the current step, and ETA, with a Stop button.
    /// Falls back to an arrow icon when there is no map URL (no token).
    static func navigation(
        mapURL: String?,
        title: String,
        step: String,
        eta: String,
        mode: TransportMode,
        onStop: @escaping @Sendable () -> Void,
        onWalk: @escaping @Sendable () -> Void,
        onDrive: @escaping @Sendable () -> Void
    ) -> FlexBox {
        // The mode was previously decided by how the request was phrased and
        // never shown, so a walking route to somewhere 5 km away could only
        // be fixed by asking again. The active mode is the primary button.
        let buttons: [Button] = [
            Button(
                label: "Walk", style: mode == .walking ? .primary : .secondary,
                onClick: onWalk
            ),
            Button(
                label: "Drive", style: mode == .driving ? .primary : .secondary,
                onClick: onDrive
            ),
            Button(label: "Stop", style: .secondary, onClick: onStop),
        ]

        return FlexBox(direction: .column, spacing: 12) {
            if let mapURL {
                Image(uri: mapURL, sizePreset: .fill, cornerRadius: .medium)
            } else {
                FlexBox(direction: .row, spacing: 12, crossAlignment: .center) {
                    Icon(name: .compassNorthUpRed)
                    Text(title, style: .heading)
                }
            }
            FlexBox(direction: .column, spacing: 4) {
                Text(step, style: .body)
                Text("\(title) - \(eta)", style: .meta, color: .secondary)
            }
            .padding(16)
            .background(.card)

            FlexBox(
                direction: .row, spacing: 8,
                alignment: .center, crossAlignment: .center, wrap: true
            ) {
                for button in buttons {
                    button
                }
            }
        }
    }

    /// Definition reply: picture (when found) above the description text.
    static func definition(text: String, imageURL: String?) -> FlexBox {
        FlexBox(direction: .column, spacing: 12) {
            if let imageURL {
                Image(uri: imageURL, sizePreset: .fill, cornerRadius: .medium)
            }
            FlexBox(direction: .column) {
                Text(text, style: .body)
            }
            .padding(24)
            .background(.card)
        }
    }

    /// Encounter capture: photo taken, waiting for the spoken note.
    static func encounterPrompt() -> FlexBox {
        FlexBox(direction: .column, spacing: 8) {
            FlexBox(direction: .row, spacing: 12, crossAlignment: .center) {
                Icon(name: .fourCornerFrame)
                Text("Who is this?", style: .heading)
            }
            Text("Say a note - name, where you met, follow-up",
                 style: .meta, color: .secondary)
        }
        .padding(24)
    }

    /// Conversation capture running: everything said is being noted.
    static func recording() -> FlexBox {
        FlexBox(direction: .column, spacing: 8) {
            FlexBox(direction: .row, spacing: 12, crossAlignment: .center) {
                Icon(name: .fourCornerFrame)
                Text("Recording", style: .heading)
            }
            Text("Saving this conversation - say \"stop recording\" to finish",
                 style: .meta, color: .secondary)
        }
        .padding(24)
    }

    /// Build Check: step number, the instruction (or an open flag), a hint.
    static func buildCheck(step: Int, total: Int, text: String, flag: String?) -> FlexBox {
        FlexBox(direction: .column, spacing: 8) {
            FlexBox(direction: .row, spacing: 12, crossAlignment: .center) {
                Icon(name: .fourCornerFrame)
                Text("Step \(step) of \(total)", style: .heading)
            }
            Text(flag ?? text, style: .body)
            Text(flag == nil ? "Say \"step done\" when finished" : "Confirmed · ignore · fixed",
                 style: .meta, color: .secondary)
        }
        .padding(24)
    }

    /// Encounter saved confirmation. Shows the start of the note so the
    /// user can see the transcription landed sanely.
    static func encounterSaved(note: String) -> FlexBox {
        FlexBox(direction: .column, spacing: 8) {
            FlexBox(direction: .row, spacing: 12, crossAlignment: .center) {
                Icon(name: .checkmarkCircle)
                Text("Saved", style: .heading)
            }
            Text(note, style: .body, color: .secondary)
        }
        .padding(24)
    }

    /// Blank the lens (idle state).
    static func blank() -> FlexBox {
        FlexBox(direction: .column) {}
    }

    /// Static screen for the test panel's Display button.
    static func testScreen() -> FlexBox {
        FlexBox(direction: .column, spacing: 8) {
            Text("Hermes display", style: .heading)
            Text("Connected - this is a test screen", style: .body, color: .secondary)
        }
        .padding(24)
    }
}
