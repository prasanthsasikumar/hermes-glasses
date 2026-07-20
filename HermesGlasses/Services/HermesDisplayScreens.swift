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

    /// The reply card. Stop appears only while TTS is playing.
    /// ComponentBuilder has no buildOptional, so conditional buttons are
    /// prebuilt as an array and emitted with a for-loop (buildArray).
    static func reply(
        text: String,
        speaking: Bool,
        onStop: @escaping @Sendable () -> Void,
        onRepeat: @escaping @Sendable () -> Void,
        onNewChat: @escaping @Sendable () -> Void
    ) -> FlexBox {
        var buttons: [Button] = []
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
        onStop: @escaping @Sendable () -> Void
    ) -> FlexBox {
        FlexBox(direction: .column, spacing: 12) {
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
            Button(label: "Stop", style: .primary, onClick: onStop)
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
