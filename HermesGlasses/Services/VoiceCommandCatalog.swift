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
                id: "buildcheck",
                title: "Check an assembly",
                summary: "Photographs your work every few seconds and checks it against a procedure you imported. Everything you say during a run is logged against the current step.",
                examples: ["Start build check"],
                followUp: "Say \"step done\" to move on, \"end build check\" to save the run.",
                phrases: IntentDetector.buildCheckStartCommands.sorted()
                    + IntentDetector.buildStepDoneCommands.sorted()
                    + IntentDetector.buildCheckEndCommands.sorted(),
                setting: nil
            ),
            VoiceCommandGroup(
                id: "buildcheck-replies",
                title: "Answer a Build Check warning",
                summary: "Heard for 20 seconds after a warning. Every answer is saved with the flag.",
                examples: ["Confirmed", "False alarm", "Fixed", "Override"],
                followUp: "\"Fixed\" checks the step again right away. \"Override\" moves past a blocked critical step and is recorded in red.",
                phrases: IntentDetector.buildConfirmCommands.sorted()
                    + IntentDetector.buildIgnoreCommands.sorted()
                    + IntentDetector.buildFixedCommands.sorted()
                    + IntentDetector.buildOverrideCommands.sorted()
                    + IntentDetector.buildRepeatCommands.sorted(),
                setting: nil
            ),
            VoiceCommandGroup(
                id: "machineguide",
                title: "Get help with a machine",
                summary: "Takes a photo of the machine in front of you, finds its manual among the ones you imported, and answers out loud from it. From then on every question goes to that manual.",
                examples: ["Help me assemble this", "Which machine is this", "Start machine guide"],
                followUp: "Then just ask: \"first step\", \"next\", \"what's the torque for these bolts\", \"is this right?\"",
                phrases: IntentDetector.machineGuideTriggers.map { "\(placeholder) \($0) \(placeholder)" }
                    + IntentDetector.machineIdentifyCommands.sorted()
                    + IntentDetector.machineGuideStartCommands.sorted(),
                setting: "Manuals → Start by voice"
            ),
            VoiceCommandGroup(
                id: "machineguide-during",
                title: "While the machine guide is on",
                summary: "Move to another machine, name the machine yourself when the camera can't tell, or switch the guide off.",
                examples: ["Which machine is this", "This is Machine B", "Stop the guide"],
                followUp: "\"This is …\" takes the name you gave the manual on the Manuals screen.",
                phrases: IntentDetector.machineGuideStopCommands.sorted(),
                setting: nil
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
