//
// Standalone tests for IntentDetector + NavigationFormat. No XCTest target,
// so build via swiftc:
//   xcrun swiftc \
//     HermesGlasses/Services/Navigation/NavigationTypes.swift \
//     HermesGlasses/Services/Navigation/IntentDetector.swift \
//     tests/intent/main.swift -o /tmp/intent-tests && /tmp/intent-tests
//
import Foundation

var failures = 0
func expectEqual<T: Equatable>(_ got: T, _ want: T, _ label: String) {
    if got == want { print("PASS \(label)") }
    else { failures += 1; print("FAIL \(label)\n  got:  \(got)\n  want: \(want)") }
}

// Navigation intents
expectEqual(IntentDetector.detect("take me to Blue Bottle Coffee"),
            .navigate(destination: "Blue Bottle Coffee", mode: .walking), "take me to")
expectEqual(IntentDetector.detect("navigate to the Ferry Building"),
            .navigate(destination: "the Ferry Building", mode: .walking), "navigate to")
expectEqual(IntentDetector.detect("I want to go to Golden Gate Park"),
            .navigate(destination: "Golden Gate Park", mode: .walking), "i want to go to")
expectEqual(IntentDetector.detect("directions to City Hall"),
            .navigate(destination: "City Hall", mode: .walking), "directions to")
expectEqual(IntentDetector.detect("drive me to the airport"),
            .navigate(destination: "the airport", mode: .driving), "drive -> driving mode")
expectEqual(IntentDetector.detect("how do I get to the museum driving"),
            .navigate(destination: "the museum", mode: .driving), "trailing driving keyword")

// Stop
expectEqual(IntentDetector.detect("stop navigation"), .stopNavigation, "stop navigation")
expectEqual(IntentDetector.detect("cancel navigation"), .stopNavigation, "cancel navigation")

// Definitions
expectEqual(IntentDetector.detect("what is a potato"),
            .define(subject: "potato"), "what is a")
expectEqual(IntentDetector.detect("what's an axolotl"),
            .define(subject: "axolotl"), "what's an")
expectEqual(IntentDetector.detect("tell me about the Eiffel Tower"),
            .define(subject: "the Eiffel Tower"), "tell me about")

// Negatives
expectEqual(IntentDetector.detect("what time is it"), .none, "no false define")
expectEqual(IntentDetector.detect("hello there"), .none, "plain chat")

// Formatting
expectEqual(NavigationFormat.eta(seconds: 360), "6 min", "eta minutes")
expectEqual(NavigationFormat.eta(seconds: 30), "1 min", "eta rounds up to 1")
expectEqual(NavigationFormat.distance(meters: 300), "300 m", "distance meters")
expectEqual(NavigationFormat.distance(meters: 1500), "1.5 km", "distance km")

expectEqual(IntentDetector.detect("who is Ada Lovelace"),
            .define(subject: "Ada Lovelace"), "who is")
expectEqual(IntentDetector.detect("what are tectonic plates"),
            .define(subject: "tectonic plates"), "what are")
expectEqual(IntentDetector.detect("take me to the station by car"),
            .navigate(destination: "the station", mode: .driving), "by car -> driving")
expectEqual(IntentDetector.detect("navigate to the park on foot"),
            .navigate(destination: "the park", mode: .walking), "on foot -> walking")

// Remember-a-person (whole-utterance commands)
expectEqual(IntentDetector.detect("remember this person"), .rememberPerson, "remember this person")
expectEqual(IntentDetector.detect("Remember this person."), .rememberPerson, "case + punctuation")
expectEqual(IntentDetector.detect("hey remember her"), .rememberPerson, "leading filler stripped")
expectEqual(IntentDetector.detect("new contact"), .rememberPerson, "new contact")
expectEqual(IntentDetector.detect("remember this face"), .rememberPerson, "remember this face")

// ...and the words that must NOT trigger it
expectEqual(IntentDetector.detect("remember to email her tomorrow"), .none, "remember to ... is not a capture")
expectEqual(IntentDetector.detect("I remember this person from the conference"), .none, "mid-sentence remember")
expectEqual(IntentDetector.detect("what is a person"), .define(subject: "person"), "define still wins its own phrasing")

// Cancellation is only consulted while a note is pending
expectEqual(IntentDetector.isEncounterCancellation("cancel"), true, "cancel")
expectEqual(IntentDetector.isEncounterCancellation("Never mind."), true, "never mind")
expectEqual(IntentDetector.isEncounterCancellation("Sarah from Meta"), false, "a real note is not a cancel")

// Conversation capture (whole-utterance commands)
expectEqual(IntentDetector.detect("record this conversation"),
            .startConversationCapture, "record this conversation")
expectEqual(IntentDetector.detect("Start recording."),
            .startConversationCapture, "start recording, case + punctuation")
expectEqual(IntentDetector.detect("hey start taking notes"),
            .startConversationCapture, "leading filler stripped")
expectEqual(IntentDetector.detect("I was recording a video yesterday"),
            .none, "mid-sentence recording is not a capture")
expectEqual(IntentDetector.detect("record"), .none, "bare 'record' is too weak")

// Stop is only consulted while a capture is running
expectEqual(IntentDetector.isConversationStop("stop recording"), true, "stop recording")
expectEqual(IntentDetector.isConversationStop("Save the conversation!"), true, "save the conversation")
expectEqual(IntentDetector.isConversationStop("please stop recording"), true, "polite stop")
expectEqual(IntentDetector.isConversationStop("we should stop meeting like this"),
            false, "conversation speech is not a stop")
expectEqual(IntentDetector.isConversationStop("she kept recording everything"),
            false, "mid-sentence recording is not a stop")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURES")
exit(failures == 0 ? 0 : 1)
