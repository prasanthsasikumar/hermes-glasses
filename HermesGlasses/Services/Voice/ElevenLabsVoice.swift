//
// ElevenLabsVoice.swift
//
// The natural voice: whether it is on, where its key lives, and one call
// that turns a sentence into MP3. The key is read from the Keychain first
// (pasted in Settings -> Voice) and otherwise from the build
// (ELEVENLABS_API_KEY in the gitignored Config/Secrets.xcconfig, surfaced
// through Info.plist) so a developer build talks without any typing.
//

import Foundation

enum ElevenLabsVoice {
    static let enabledKey = "elevenlabs_enabled"
    static let voiceIDKey = "elevenlabs_voice_id"
    private static let keychainID = "elevenlabs"

    struct Failure: LocalizedError {
        let status: Int
        let message: String
        var isFatal: Bool { ElevenLabsRequest.isFatal(status: status) }
        var errorDescription: String? { message }
    }

    enum KeySource { case settings, build, none }

    /// On unless switched off - but only ever ACTIVE with a key.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    private static func buildValue(_ name: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: name) as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static var keySource: KeySource {
        if DirectClient.hasKey(for: keychainID) { return .settings }
        return buildValue("ElevenLabsAPIKey") == nil ? .none : .build
    }

    static var apiKey: String? {
        DirectClient.loadKey(for: keychainID) ?? buildValue("ElevenLabsAPIKey")
    }

    /// An empty string removes the stored key (a build key, if any, then
    /// applies again). False = the Keychain refused the write.
    @discardableResult
    static func storeKey(_ key: String) -> Bool {
        DirectClient.storeKey(key, for: keychainID)
    }

    static var voiceID: String {
        get {
            let stored = UserDefaults.standard.string(forKey: voiceIDKey) ?? ""
            if !stored.isEmpty { return stored }
            return buildValue("ElevenLabsVoiceID") ?? ElevenLabsRequest.defaultVoiceID
        }
        set { UserDefaults.standard.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: voiceIDKey) }
    }

    static var isActive: Bool { isEnabled && apiKey != nil }

    private static let warmLock = NSLock()
    private static var lastWarmUp = Date.distantPast

    /// Open the connection BEFORE there is anything to say. The first
    /// request to a host pays for DNS and a TLS handshake (measured: about
    /// a second); doing that while the model is still thinking means the
    /// first sentence doesn't. At most once every 30 s; carries no key.
    static func warmUp() {
        guard isActive else { return }
        let due: Bool = warmLock.withLock {
            guard Date().timeIntervalSince(lastWarmUp) > 30 else { return false }
            lastWarmUp = Date()
            return true
        }
        guard due, let url = URL(string: "https://api.elevenlabs.io/") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request).resume()
    }

    /// One piece of speech as MP3. Throws `Failure` for an HTTP error.
    static func fetch(_ text: String) async throws -> Data {
        guard let key = apiKey else { throw Failure(status: 401, message: "No ElevenLabs key.") }
        let request = try ElevenLabsRequest.speech(text: text, key: key, voiceID: voiceID)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, !data.isEmpty else {
            throw Failure(status: status, message: ElevenLabsRequest.message(status: status, body: data))
        }
        return data
    }
}
