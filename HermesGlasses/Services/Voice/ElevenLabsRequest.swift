//
// ElevenLabsRequest.swift
//
// The wire format of one ElevenLabs text-to-speech call, and how to read a
// failure. Foundation only; tested in tests/voice. Where the key comes
// from and how the audio is played live in ElevenLabsVoice.swift and
// HermesSpeechSynthesizer.swift.
//

import Foundation

enum ElevenLabsRequest {
    /// Flash: the low-latency model. A sentence comes back in a few
    /// hundred milliseconds, which is the whole point of using it here.
    static let model = "eleven_flash_v2_5"
    /// "Sarah" - used when no voice id is configured.
    static let defaultVoiceID = "EXAVITQu4vr4xnSDxMaL"
    /// MP3 because AVAudioPlayer plays it straight from memory and every
    /// ElevenLabs plan can produce it.
    static let outputFormat = "mp3_44100_128"
    static let timeout: TimeInterval = 10

    enum RequestError: Error { case missingKey, badVoice }

    static func speech(text: String, key: String, voiceID: String) throws -> URLRequest {
        guard !key.isEmpty else { throw RequestError.missingKey }
        let allowed = CharacterSet.alphanumerics
        guard !voiceID.isEmpty,
              let voice = voiceID.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voice)?output_format=\(outputFormat)")
        else { throw RequestError.badVoice }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = timeout
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": text,
            "model_id": model,
        ])
        return request
    }

    /// A rejected key or a plan without access won't fix itself: stop
    /// asking for the rest of the session. A rate limit or a server error
    /// is a blip - the next sentence may well go through.
    static func isFatal(status: Int) -> Bool { status == 401 || status == 403 }

    static func message(status: Int, body: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let detail = json["detail"] as? [String: Any], let message = detail["message"] as? String {
                return message
            }
            if let detail = json["detail"] as? String { return detail }
        }
        return "ElevenLabs error \(status)."
    }
}
