import Foundation
import Testing
@testable import TidytalkCore

@Suite struct AppConfigTests {
    @Test func missingFieldsUseDefaults() throws {
        let config = try AppConfig.decode(Data(#"{"ai": {"api_key": "sk-1"}}"#.utf8))
        #expect(config.cleanupEnabled)
        #expect(config.ai.apiKey == "sk-1")
        #expect(config.ai.baseURL == AIConfig.default.baseURL)
        #expect(config.ai.model == AIConfig.default.model)
        #expect(config.ai.temperature == 0)
    }

    @Test func nullTemperatureIsOmitted() throws {
        let config = try AppConfig.decode(Data(#"{"ai": {"temperature": null}}"#.utf8))
        #expect(config.ai.temperature == nil)
    }

    @Test func roundTripKeepsUnknownFields() throws {
        let original = Data(#"{"extra": 1, "ai": {"note": "x", "model": "m"}}"#.utf8)
        var config = try AppConfig.decode(original)
        config.ai.apiKey = "sk-2"
        config.cleanupEnabled = false
        let data = try config.encode(merging: original)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["extra"] as? Int == 1)
        #expect((root["ai"] as? [String: Any])?["note"] as? String == "x")
        #expect(try AppConfig.decode(data) == config)
    }

    @Test func appearanceAndDiarizeRoundTrip() throws {
        // 没写时跟随系统、区分说话人；不认识的值也当跟随系统
        let defaults = try AppConfig.decode(Data(#"{"appearance": "sepia"}"#.utf8))
        #expect(defaults.appearance == .system)
        #expect(defaults.meetingDiarize)
        var config = defaults
        config.appearance = .dark
        config.meetingDiarize = false
        let data = try config.encode(merging: Data("{}".utf8))
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["appearance"] as? String == "dark")
        #expect(root["meeting_diarize"] as? Bool == false)
        #expect(try AppConfig.decode(data) == config)
    }

    @Test func rejectsNonObject() {
        #expect(throws: (any Error).self) { try AppConfig.decode(Data("[1]".utf8)) }
        #expect(throws: (any Error).self) { try AppConfig.decode(Data("{oops".utf8)) }
    }

    @Test func chatCompletionsURL() {
        var ai = AIConfig.default
        ai.baseURL = "https://api.openai.com/v1/"
        #expect(ai.chatCompletionsURL?.absoluteString == "https://api.openai.com/v1/chat/completions")
        ai.baseURL = "api.openai.com"
        #expect(ai.chatCompletionsURL == nil)
        #expect(!ai.isConfigured)
    }
}
