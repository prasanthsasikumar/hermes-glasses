//
// VoiceCommandCatalog.swift
//
// The in-app reference for what you can say. Every phrase list here is
// read STRAIGHT OUT of the detector that matches it (IntentDetector,
// VisualQueryDetector) - so the tester-facing list cannot drift away from
// what the app actually recognizes. Add a trigger to a detector and it
// shows up here automatically.
//

import Foundation

struct VoiceCommandGroup: Identifiable {
    let id: String
    /// Section heading, e.g. "Remember a person"
    let title: String
    /// One line on what saying it does
    let summary: String
    /// Full sentences a tester can read out verbatim
    let examples: [String]
    /// What happens next, when the command starts a two-step exchange.
    /// Rendered as prose, not as something to say verbatim.
    let followUp: String?
    /// Every recognized trigger, for the "all phrases" disclosure
    let phrases: [String]
    /// Human name of the setting that gates this group (nil = always on)
    let setting: String?
}

enum VoiceCommandCatalog {
    /// `…` marks where the tester supplies their own words.
    private static let placeholder = "…"

    static var groups: [VoiceCommandGroup] {
        [
            VoiceCommandGroup(
                id: "people",
                title: "Remember a person",
                summary: "Takes a glasses photo, then saves whatever you say next as the note. Say it once per person; find them all later on the People screen.",
                examples: ["Remember this person"],
                followUp: "Then speak the note, e.g. \"Sarah from Meta, AR input team, send her the demo link\".",
                phrases: IntentDetector.rememberCommands.sorted(),
                setting: "People → Remember people I meet"
            ),
            VoiceCommandGroup(
                id: "people-cancel",
                title: "Throw a capture away",
                summary: "Say instead of the note, right after the photo. Staying silent for 30 seconds keeps the photo with an empty note.",
                examples: ["Cancel", "Never mind"],
                followUp: nil,
                phrases: IntentDetector.cancelWords.sorted(),
                setting: nil
            ),
            VoiceCommandGroup(
                id: "conversation",
                title: "Record a conversation",
                summary: "Saves everything said as one note until you stop it. Looking at a person for 2 seconds adds their photo; every person you look at gets added.",
                examples: ["Record this conversation", "Start taking notes"],
                followUp: "Say \"stop recording\" (or \"save the conversation\") to finish - the note and all photos land on the People screen.",
                phrases: IntentDetector.conversationStartCommands.sorted()
                    + IntentDetector.conversationStopCommands.sorted(),
                setting: "People → Remember people I meet"
            ),
            VoiceCommandGroup(
                id: "navigate",
                title: "Navigate somewhere",
                summary: "Puts a map and turn-by-turn directions on the lens. Add \"driving\" or \"by car\" for driving directions; walking is the default.",
                examples: [
                    "Take me to Blue Bottle Coffee",
                    "Drive me to the airport",
                    "How do I get to the museum driving",
                ],
                followUp: nil,
                phrases: IntentDetector.navTriggers.map { "\($0) \(placeholder)" },
                setting: "Navigation & Maps → Navigate on \"take me to…\""
            ),
            VoiceCommandGroup(
                id: "navigate-stop",
                title: "Stop navigating",
                summary: "Clears the map from the lens.",
                examples: ["Stop navigation"],
                followUp: nil,
                phrases: IntentDetector.stopPhrases.sorted(),
                setting: nil
            ),
            VoiceCommandGroup(
                id: "define",
                title: "Look something up",
                summary: "Answers normally and adds a Wikipedia picture on the lens.",
                examples: [
                    "What is an axolotl",
                    "Tell me about the Eiffel Tower",
                    "Who is Ada Lovelace",
                ],
                followUp: nil,
                phrases: IntentDetector.defineTriggers.map { "\($0) \(placeholder)" },
                setting: "Navigation & Maps → Show a picture on \"what is…\""
            ),
            VoiceCommandGroup(
                id: "visual",
                title: "Ask about what you see",
                summary: "Takes a photo through the glasses and sends it with your question. Also triggers on \"this\"/\"that\" plus a concrete noun.",
                examples: [
                    "What am I looking at",
                    "Read this for me",
                    "What's this plant",
                ],
                followUp: nil,
                phrases: VisualQueryDetector.keywords.sorted(),
                setting: nil
            ),
        ]
    }
}
