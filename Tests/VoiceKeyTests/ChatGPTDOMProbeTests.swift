import JavaScriptCore
@testable import VoiceKey
import XCTest

final class ChatGPTDOMProbeTests: XCTestCase {
    func testFindsVoiceModeButton() {
        let element = evaluateElement(
            expression: "VoiceKeyProbe.findVoiceStartElement(fixture)",
            fixture: [
                button(ariaLabel: "Attach file", dataTestId: "composer-plus-btn"),
                button(ariaLabel: "Start voice mode", dataTestId: "voice-mode-button")
            ]
        )

        XCTAssertEqual(element?["dataTestId"] as? String, "voice-mode-button")
    }

    func testDoesNotMistakeDictationForVoiceMode() {
        let element = evaluateElement(
            expression: "VoiceKeyProbe.findVoiceStartElement(fixture)",
            fixture: [
                button(ariaLabel: "Dictate message", dataTestId: "composer-speech-button"),
                button(ariaLabel: "Microphone button", dataTestId: "composer-mic-button")
            ]
        )

        XCTAssertNil(element)
    }

    func testDetectsLoginRequiredWhenComposerIsAbsent() {
        let state = evaluateString(
            expression: "VoiceKeyProbe.snapshot(fixture, 'https://chatgpt.com/auth/login', 'ChatGPT Log in').state",
            fixture: [
                button(text: "Log in"),
                button(text: "Sign up")
            ]
        )

        XCTAssertEqual(state, "loginRequired")
    }

    func testDetectsVoiceActiveFromEndControl() {
        let state = evaluateString(
            expression: "VoiceKeyProbe.snapshot(fixture, 'https://chatgpt.com/', 'Voice mode').state",
            fixture: [
                button(ariaLabel: "End voice", dataTestId: "voice-end-button")
            ]
        )

        XCTAssertEqual(state, "voiceActive")
    }

    func testVoiceStopControlIsNotAStartCandidate() {
        let element = evaluateElement(
            expression: "VoiceKeyProbe.findVoiceStartElement(fixture)",
            fixture: [
                button(ariaLabel: "Stop", dataTestId: "voice-stop-button")
            ]
        )

        XCTAssertNil(element)
    }

    private func evaluateElement(expression: String, fixture: [[String: Any]]) -> [String: Any]? {
        let context = makeContext(fixture: fixture)
        let value = context.evaluateScript(expression)
        guard let dictionary = value?.toDictionary() as? [String: Any], !value!.isNull else {
            return nil
        }
        return dictionary
    }

    private func evaluateString(expression: String, fixture: [[String: Any]]) -> String? {
        let context = makeContext(fixture: fixture)
        return context.evaluateScript(expression)?.toString()
    }

    private func makeContext(fixture: [[String: Any]]) -> JSContext {
        let context = JSContext()!
        context.evaluateScript(ChatGPTDOMProbe.coreScript)
        context.setObject(fixture, forKeyedSubscript: "fixture" as NSString)
        return context
    }

    private func button(
        ariaLabel: String? = nil,
        dataTestId: String? = nil,
        title: String? = nil,
        text: String? = nil
    ) -> [String: Any] {
        [
            "ariaLabel": ariaLabel as Any,
            "dataTestId": dataTestId as Any,
            "title": title as Any,
            "text": text as Any,
            "role": "button",
            "visible": true,
            "x": 120.0,
            "y": 80.0,
            "width": 44.0,
            "height": 44.0
        ]
    }
}
