@testable import VoiceKey
import Foundation
import XCTest

final class OpenClawTalkLifecycleTests: XCTestCase {
    func testSignedHandshakeCreatesReadyRelaySession() throws {
        let socket = ScriptedOpenClawWebSocket(messages: liveSessionMessages())
        let audioEngine = LifecycleAudioEngine()
        let watchdogs = ManualWatchdogScheduler()
        let provider = makeProvider(
            audioEngine: audioEngine,
            sockets: [socket],
            watchdogs: watchdogs,
            deviceCredentials: deviceCredentials
        )

        let listening = expectation(description: "session ready")
        provider.onEvent = { event in
            guard case .status(.listening) = event else { return }
            listening.fulfill()
        }

        provider.toggleVoice()
        wait(for: [listening], timeout: 1)

        XCTAssertEqual(audioEngine.startCount, 1)
        XCTAssertEqual(socket.sentMethods, ["connect", "talk.session.create"])
        let connect = try XCTUnwrap(socket.sentFrames.first)
        let params = try XCTUnwrap(connect["params"] as? [String: Any])
        XCTAssertNotNil(params["device"] as? [String: Any])
        XCTAssertEqual(params["scopes"] as? [String], ["operator.talk", "operator.write"])
        // caps must be TOP-LEVEL: the gateway's client object is
        // additionalProperties:false and rejects a nested caps (live
        // incident 2026-07-24: "unexpected property 'caps'").
        XCTAssertEqual(params["caps"] as? [String], ["tool-events"])
        let client = try XCTUnwrap(params["client"] as? [String: Any])
        XCTAssertNil(client["caps"])
        let auth = try XCTUnwrap(params["auth"] as? [String: Any])
        XCTAssertEqual(auth["deviceToken"] as? String, "device-token")
    }

    func testDeviceTokenMismatchRetriesWithoutTokenAndAdoptsSuccessfulHello() throws {
        let mismatchSocket = ScriptedOpenClawWebSocket(messages: [
            #"{"type":"event","event":"connect.challenge","payload":{"nonce":"nonce-1","ts":1}}"#,
            """
            {"type":"res","id":"1","ok":false,"error":{"code":"INVALID_REQUEST",\
            "message":"unauthorized: device token mismatch (rotate/reissue device token)",\
            "details":{"code":"AUTH_DEVICE_TOKEN_MISMATCH",\
            "authReason":"device_token_mismatch","canRetryWithDeviceToken":false,\
            "recommendedNextStep":"update_auth_credentials"}}}
            """
        ])
        let repairedSocket = ScriptedOpenClawWebSocket(messages: [
            #"{"type":"event","event":"connect.challenge","payload":{"nonce":"nonce-2","ts":2}}"#,
            """
            {"type":"res","id":"1","result":{"type":"hello-ok","protocol":4,\
            "server":{"version":"2026.7.1-2"},\
            "auth":{"role":"operator","scopes":["operator.talk","operator.write"],\
            "deviceToken":"canonical-device-token","issuedAtMs":1784300000000}}}
            """,
            #"{"type":"res","id":"2","ok":true,"payload":{"sessionId":"session-1","relaySessionId":"relay-1"}}"#,
            #"{"type":"event","event":"talk.event","payload":{"relaySessionId":"relay-1","type":"ready"}}"#
        ])
        let factory = ScriptedOpenClawWebSocketFactory(
            sockets: [mismatchSocket, repairedSocket]
        )
        let provider = makeProvider(
            audioEngine: LifecycleAudioEngine(),
            socketFactory: factory,
            watchdogs: ManualWatchdogScheduler(),
            deviceCredentials: deviceCredentials
        )

        let listening = expectation(description: "repaired session ready")
        provider.onEvent = { event in
            guard case .status(.listening) = event else { return }
            listening.fulfill()
        }
        provider.toggleVoice()
        wait(for: [listening], timeout: 1)

        XCTAssertEqual(
            factory.requestedURLs.map(\.absoluteString),
            ["ws://127.0.0.1:18790", "ws://127.0.0.1:18790"]
        )
        let initialParams = try XCTUnwrap(
            mismatchSocket.sentFrames.first?["params"] as? [String: Any]
        )
        XCTAssertEqual(
            (initialParams["auth"] as? [String: Any])?["deviceToken"] as? String,
            "device-token"
        )
        let repairedParams = try XCTUnwrap(
            repairedSocket.sentFrames.first?["params"] as? [String: Any]
        )
        XCTAssertNil((repairedParams["auth"] as? [String: Any])?["deviceToken"])
        XCTAssertNotNil(repairedParams["device"])
        XCTAssertEqual(
            OpenClawTalkEventMapper.actions(
                from: """
                    {"type":"res","id":"1","result":{"type":"hello-ok",\
                    "auth":{"deviceToken":"canonical-device-token"}}}
                    """,
                sessionID: nil
            ).first,
            .connected(deviceToken: "canonical-device-token")
        )
    }

    func testPairingFailureSurfacesLatestRequestAndRemediationHint() {
        func pairingFrame(requestID: String) -> String {
            """
            {"type":"res","id":"1","ok":false,"error":{"code":"NOT_PAIRED",\
            "message":"pairing required: device identity changed and must be re-approved",\
            "details":{"code":"PAIRING_REQUIRED","reason":"metadata-upgrade",\
            "requestId":"\(requestID)",\
            "remediationHint":"Approve the current pending request.",\
            "approvedScopes":["operator.talk","operator.write"]}}}
            """
        }
        let firstSocket = ScriptedOpenClawWebSocket(messages: [
            #"{"type":"event","event":"connect.challenge","payload":{"nonce":"nonce-1"}}"#,
            pairingFrame(requestID: "expired-request")
        ])
        let retrySocket = ScriptedOpenClawWebSocket(messages: [
            #"{"type":"event","event":"connect.challenge","payload":{"nonce":"nonce-2"}}"#,
            pairingFrame(requestID: "latest-request")
        ])
        let provider = makeProvider(
            audioEngine: LifecycleAudioEngine(),
            sockets: [firstSocket, retrySocket],
            watchdogs: ManualWatchdogScheduler(),
            deviceCredentials: deviceCredentials
        )

        let surfaced = expectation(description: "latest pairing request surfaced")
        provider.onEvent = { event in
            guard case let .status(.needsAttention(message)) = event,
                  message.contains("latest-request"),
                  message.contains("Approve the current pending request."),
                  message.contains("expired-request") == false else { return }
            surfaced.fulfill()
        }
        provider.toggleVoice()
        wait(for: [surfaced], timeout: 1)
    }

    func testFatalAudioFailureStopsSessionAndSurfacesNeedsAttention() {
        let socket = ScriptedOpenClawWebSocket(messages: liveSessionMessages())
        let audioEngine = LifecycleAudioEngine()
        let watchdogs = ManualWatchdogScheduler()
        let provider = makeProvider(
            audioEngine: audioEngine,
            sockets: [socket],
            watchdogs: watchdogs
        )
        let listening = expectation(description: "session ready")
        let failure = expectation(description: "fatal audio failure surfaced")
        provider.onEvent = { event in
            switch event {
            case .status(.listening):
                listening.fulfill()
            case let .status(.needsAttention(message))
                where message.contains("Microphone audio stopped"):
                failure.fulfill()
            default:
                break
            }
        }

        provider.toggleVoice()
        wait(for: [listening], timeout: 1)
        audioEngine.triggerFatalFailure()

        wait(for: [failure], timeout: 1)
        XCTAssertEqual(audioEngine.stopCount, 1)
        XCTAssertEqual(socket.cancelCount, 1)
        XCTAssertEqual(socket.invalidateCount, 1)
    }

    func testSilentCandidateWatchdogFallsBackToNextEndpoint() {
        let silentSocket = ScriptedOpenClawWebSocket()
        let fallbackSocket = ScriptedOpenClawWebSocket(messages: liveSessionMessages())
        let audioEngine = LifecycleAudioEngine()
        let watchdogs = ManualWatchdogScheduler()
        let factory = ScriptedOpenClawWebSocketFactory(
            sockets: [silentSocket, fallbackSocket]
        )
        let provider = makeProvider(
            audioEngine: audioEngine,
            socketFactory: factory,
            watchdogs: watchdogs
        )

        let listening = expectation(description: "fallback session ready")
        provider.onEvent = { event in
            guard case .status(.listening) = event else { return }
            listening.fulfill()
        }

        provider.toggleVoice()
        XCTAssertTrue(watchdogs.fireNextActive())
        wait(for: [listening], timeout: 1)

        XCTAssertEqual(
            factory.requestedURLs.map(\.absoluteString),
            ["ws://127.0.0.1:18790", "ws://127.0.0.1:18789"]
        )
        XCTAssertEqual(silentSocket.cancelCount, 1)
        XCTAssertEqual(silentSocket.invalidateCount, 1)
        XCTAssertEqual(fallbackSocket.sentMethods, ["connect", "talk.session.create"])
        XCTAssertEqual(audioEngine.startCount, 1)
    }

    func testStopDuringLiveSessionSendsCloseInvalidatesSocketAndDropsLateSendError() {
        let socket = ScriptedOpenClawWebSocket(
            messages: liveSessionMessages(),
            deferredCompletionMethod: "talk.session.close"
        )
        let audioEngine = LifecycleAudioEngine()
        let watchdogs = ManualWatchdogScheduler()
        let provider = makeProvider(
            audioEngine: audioEngine,
            sockets: [socket],
            watchdogs: watchdogs
        )

        let listening = expectation(description: "session ready")
        let unexpectedAttention = expectation(description: "no teardown error")
        unexpectedAttention.isInverted = true
        provider.onEvent = { event in
            switch event {
            case .status(.listening):
                listening.fulfill()
            case .status(.needsAttention):
                unexpectedAttention.fulfill()
            default:
                break
            }
        }

        provider.toggleVoice()
        wait(for: [listening], timeout: 1)
        provider.stopVoice()

        XCTAssertEqual(socket.sentMethods.last, "talk.session.close")
        XCTAssertEqual(socket.cancelCount, 1)
        XCTAssertEqual(socket.invalidateCount, 1)
        XCTAssertEqual(audioEngine.stopCount, 1)

        socket.completeDeferredSend(with: LifecycleTestError.sendFailed)
        wait(for: [unexpectedAttention], timeout: 0.2)
    }

    func testStopInvalidationAllowsProviderToDeallocate() {
        let socket = ScriptedOpenClawWebSocket(messages: liveSessionMessages())
        let audioEngine = LifecycleAudioEngine()
        let watchdogs = ManualWatchdogScheduler()
        weak var releasedProvider: OpenClawTalkProvider?

        autoreleasepool {
            let provider = makeProvider(
                audioEngine: audioEngine,
                sockets: [socket],
                watchdogs: watchdogs
            )
            releasedProvider = provider
            provider.toggleVoice()
            provider.stopVoice()
        }

        XCTAssertNil(releasedProvider)
        XCTAssertEqual(socket.invalidateCount, 1)
    }

    func testPairedDeviceChallengeWithoutNonceEmitsDiagnosticBeforeTokenFallback() throws {
        let challengeWithoutNonce = """
            {"type":"event","event":"connect.challenge","payload":{"ts":1}}
            """
        let socket = ScriptedOpenClawWebSocket(messages: [challengeWithoutNonce])
        let watchdogs = ManualWatchdogScheduler()
        let provider = makeProvider(
            audioEngine: LifecycleAudioEngine(),
            sockets: [socket],
            watchdogs: watchdogs,
            deviceCredentials: deviceCredentials
        )

        let diagnostic = expectation(description: "missing nonce diagnostic")
        provider.onEvent = { event in
            guard case let .diagnostic(message) = event,
                  message.contains("challenge omitted a nonce") else { return }
            diagnostic.fulfill()
        }

        provider.toggleVoice()
        wait(for: [diagnostic], timeout: 1)

        let connect = try XCTUnwrap(socket.sentFrames.first)
        let params = try XCTUnwrap(connect["params"] as? [String: Any])
        XCTAssertNil(params["device"])
        XCTAssertEqual(params["scopes"] as? [String], [
            "operator.talk", "operator.write", "operator.read"
        ])
    }

    func testBargeInCancelsOncePerAssistantTurnAndTranscriptDeltaDoesNotClearSpeaking() {
        let socket = ScriptedOpenClawWebSocket(messages: liveSessionMessages())
        let audioEngine = LifecycleAudioEngine()
        let watchdogs = ManualWatchdogScheduler()
        let provider = makeProvider(
            audioEngine: audioEngine,
            sockets: [socket],
            watchdogs: watchdogs
        )

        let ready = expectation(description: "ready")
        provider.onEvent = { event in
            guard case .status(.listening) = event else { return }
            ready.fulfill()
        }
        provider.toggleVoice()
        wait(for: [ready], timeout: 1)

        let firstSpeaking = expectation(description: "first turn speaking")
        provider.onEvent = { event in
            guard case .status(.speaking) = event else { return }
            firstSpeaking.fulfill()
        }
        socket.push(text: audioEnvelope(byte: 0x01))
        wait(for: [firstSpeaking], timeout: 1)

        let firstCancel = expectation(description: "first turn cancelled")
        socket.onSentMethod = { method, count in
            if method == "talk.session.cancelOutput", count == 1 {
                firstCancel.fulfill()
            }
        }
        audioEngine.emitActivity(peak: 0.5)
        wait(for: [firstCancel], timeout: 1)

        let transcriptListening = expectation(description: "user transcript delta")
        provider.onEvent = { event in
            guard case .status(.listening) = event else { return }
            transcriptListening.fulfill()
        }
        socket.push(text: audioEnvelope(byte: 0x02))
        socket.push(text: userTranscriptDelta())
        wait(for: [transcriptListening], timeout: 1)
        audioEngine.emitActivity(peak: 0.5)
        waitForStateQueue()
        XCTAssertEqual(socket.sentMethodCount("talk.session.cancelOutput"), 1)

        let nextTurnSpeaking = expectation(description: "next turn speaking")
        provider.onEvent = { event in
            guard case .status(.speaking) = event else { return }
            nextTurnSpeaking.fulfill()
        }
        socket.push(text: audioDoneEnvelope())
        socket.push(text: audioEnvelope(byte: 0x03))
        wait(for: [nextTurnSpeaking], timeout: 1)

        let secondCancel = expectation(description: "next turn cancelled")
        socket.onSentMethod = { method, count in
            if method == "talk.session.cancelOutput", count == 2 {
                secondCancel.fulfill()
            }
        }
        audioEngine.emitActivity(peak: 0.5)
        wait(for: [secondCancel], timeout: 1)
        XCTAssertEqual(socket.sentMethodCount("talk.session.cancelOutput"), 2)
    }

    func testConsultHappyPathRoundTripKeepsSessionLive() throws {
        let socket = ScriptedOpenClawWebSocket(messages: liveSessionMessages())
        let audioEngine = LifecycleAudioEngine()
        let watchdogs = ManualWatchdogScheduler()
        let provider = makeProvider(
            audioEngine: audioEngine,
            sockets: [socket],
            watchdogs: watchdogs
        )

        let ready = expectation(description: "session ready")
        provider.onEvent = { event in
            guard case .status(.listening) = event else { return }
            ready.fulfill()
        }
        provider.toggleVoice()
        wait(for: [ready], timeout: 1)

        let thinking = expectation(description: "consult thinking")
        provider.onEvent = { event in
            guard case .status(.thinking) = event else { return }
            thinking.fulfill()
        }
        socket.push(text: toolCallEnvelope(
            callID: "call-1",
            arguments: #"{"question":"status?"}"#
        ))
        wait(for: [thinking], timeout: 1)
        waitForStateQueue()

        let clientFrame = try XCTUnwrap(socket.sentFrames.last {
            $0["method"] as? String == "talk.client.toolCall"
        })
        let clientParams = try XCTUnwrap(clientFrame["params"] as? [String: Any])
        XCTAssertEqual(clientParams["sessionKey"] as? String, "agent:voice:voicekey")
        // Schema forbids extra keys; voiceSessionId must NOT be present.
        XCTAssertNil(clientParams["voiceSessionId"])
        XCTAssertEqual(clientParams["relaySessionId"] as? String, "relay-1")
        XCTAssertEqual(clientParams["callId"] as? String, "call-1")
        XCTAssertEqual(clientParams["name"] as? String, "openclaw_agent_consult")
        XCTAssertEqual(
            (clientParams["args"] as? [String: Any])?["question"] as? String,
            "status?"
        )
        // The gateway schema is additionalProperties:false — the params must
        // contain ONLY these keys, or the request is rejected on the wire.
        XCTAssertEqual(
            Set(clientParams.keys),
            ["sessionKey", "relaySessionId", "callId", "name", "args"]
        )

        let clientRequestID = try XCTUnwrap(clientFrame["id"] as? String)
        socket.push(text: successfulResponse(id: clientRequestID, payload: #"{"runId":"run-1"}"#))
        waitForStateQueue()

        let submitted = expectation(description: "tool result submitted")
        socket.onSentMethod = { method, count in
            if method == "talk.session.submitToolResult", count == 1 {
                submitted.fulfill()
            }
        }
        socket.push(text: chatLifecycle(
            runID: "run-1",
            state: "final",
            message: #"{"text":"All systems green."}"#
        ))
        wait(for: [submitted], timeout: 1)

        let submitFrame = try XCTUnwrap(socket.sentFrames.last {
            $0["method"] as? String == "talk.session.submitToolResult"
        })
        let submitParams = try XCTUnwrap(submitFrame["params"] as? [String: Any])
        XCTAssertEqual(submitParams["sessionId"] as? String, "session-1")
        XCTAssertEqual(submitParams["callId"] as? String, "call-1")
        XCTAssertEqual(
            (submitParams["result"] as? [String: Any])?["result"] as? String,
            "All systems green."
        )

        let listening = expectation(description: "listening after submit resolves")
        provider.onEvent = { event in
            guard case .status(.listening) = event else { return }
            listening.fulfill()
        }
        let submitRequestID = try XCTUnwrap(submitFrame["id"] as? String)
        socket.push(text: successfulResponse(id: submitRequestID))
        wait(for: [listening], timeout: 1)

        let speaking = expectation(description: "session remains live")
        provider.onEvent = { event in
            guard case .status(.speaking) = event else { return }
            speaking.fulfill()
        }
        socket.push(text: audioEnvelope(byte: 0x04))
        wait(for: [speaking], timeout: 1)
        XCTAssertEqual(socket.cancelCount, 0)
        XCTAssertEqual(socket.invalidateCount, 0)
        XCTAssertEqual(audioEngine.startCount, 1)
    }

    func testAgentControlDuringActiveConsultForwardsResultWithoutDisturbingConsult() throws {
        let socket = ScriptedOpenClawWebSocket(messages: liveSessionMessages())
        let watchdogs = ManualWatchdogScheduler()
        let provider = makeProvider(
            audioEngine: LifecycleAudioEngine(),
            sockets: [socket],
            watchdogs: watchdogs
        )

        let ready = expectation(description: "session ready")
        provider.onEvent = { event in
            guard case .status(.listening) = event else { return }
            ready.fulfill()
        }
        provider.toggleVoice()
        wait(for: [ready], timeout: 1)

        socket.push(text: toolCallEnvelope(callID: "consult-call"))
        waitForStateQueue()
        let consultStart = try XCTUnwrap(socket.sentFrames.last {
            $0["method"] as? String == "talk.client.toolCall"
        })
        socket.push(text: successfulResponse(
            id: try XCTUnwrap(consultStart["id"] as? String),
            payload: #"{"runId":"run-active"}"#
        ))
        waitForStateQueue()
        let watchdogScheduleCount = watchdogs.scheduledDelays.count
        XCTAssertEqual(Array(watchdogs.scheduledDelays.suffix(2)), [45, 180])

        let forwarded = expectation(description: "control diagnostic")
        let steerSent = expectation(description: "control steer sent")
        provider.onEvent = { event in
            guard case .diagnostic("OpenClaw agent control 'status' forwarded.") = event else {
                return
            }
            forwarded.fulfill()
        }
        socket.onSentMethod = { method, count in
            if method == "talk.session.steer", count == 1 {
                steerSent.fulfill()
            }
        }
        socket.push(text: toolCallEnvelope(
            callID: "control-call",
            name: "openclaw_agent_control",
            arguments: #"{"mode":"status","text":"  How is it going?  "}"#
        ))
        wait(for: [forwarded, steerSent], timeout: 1)

        let steerFrame = try XCTUnwrap(socket.sentFrames.last {
            $0["method"] as? String == "talk.session.steer"
        })
        let steerParams = try XCTUnwrap(steerFrame["params"] as? [String: Any])
        XCTAssertEqual(steerParams["sessionId"] as? String, "relay-1")
        XCTAssertEqual(steerParams["sessionKey"] as? String, "agent:voice:voicekey")
        XCTAssertEqual(steerParams["text"] as? String, "How is it going?")
        XCTAssertEqual(steerParams["mode"] as? String, "status")
        XCTAssertEqual(
            Set(steerParams.keys),
            ["sessionId", "sessionKey", "text", "mode"]
        )
        XCTAssertEqual(watchdogs.scheduledDelays.count, watchdogScheduleCount)

        socket.push(text: successfulResponse(
            id: try XCTUnwrap(steerFrame["id"] as? String),
            payload: #"{"status":"running","message":"Still working.","step":2}"#
        ))
        waitForStateQueue()

        let controlSubmit = try XCTUnwrap(socket.sentFrames.last {
            guard $0["method"] as? String == "talk.session.submitToolResult",
                  let params = $0["params"] as? [String: Any] else {
                return false
            }
            return params["callId"] as? String == "control-call"
        })
        let controlSubmitParams = try XCTUnwrap(controlSubmit["params"] as? [String: Any])
        XCTAssertEqual(controlSubmitParams["sessionId"] as? String, "session-1")
        let controlResult = try XCTUnwrap(controlSubmitParams["result"] as? [String: Any])
        XCTAssertEqual(controlResult["status"] as? String, "running")
        XCTAssertEqual(controlResult["message"] as? String, "Still working.")
        XCTAssertEqual(controlResult["step"] as? Int, 2)
        XCTAssertEqual(Set(controlResult.keys), ["status", "message", "step"])

        let stillRunning = expectation(description: "original watchdog remains active")
        provider.onEvent = { event in
            guard case let .diagnostic(message) = event,
                  message.contains("consult still running") else { return }
            stillRunning.fulfill()
        }
        XCTAssertTrue(watchdogs.fireNextActive())
        wait(for: [stillRunning], timeout: 1)

        socket.push(text: chatLifecycle(
            runID: "run-active",
            state: "final",
            message: #"{"text":"Original consult completed."}"#
        ))
        waitForStateQueue()
        let consultSubmit = try XCTUnwrap(socket.sentFrames.last {
            guard $0["method"] as? String == "talk.session.submitToolResult",
                  let params = $0["params"] as? [String: Any] else {
                return false
            }
            return params["callId"] as? String == "consult-call"
        })
        let consultSubmitParams = try XCTUnwrap(consultSubmit["params"] as? [String: Any])
        XCTAssertEqual(
            (consultSubmitParams["result"] as? [String: Any])?["result"] as? String,
            "Original consult completed."
        )

        let listening = expectation(description: "consult completes normally")
        provider.onEvent = { event in
            guard case .status(.listening) = event else { return }
            listening.fulfill()
        }
        socket.push(text: successfulResponse(
            id: try XCTUnwrap(consultSubmit["id"] as? String)
        ))
        wait(for: [listening], timeout: 1)
    }

    func testAgentControlValidationFiltersModesAndAllowsMultipleCalls() throws {
        let socket = ScriptedOpenClawWebSocket(messages: liveSessionMessages())
        let provider = makeProvider(
            audioEngine: LifecycleAudioEngine(),
            sockets: [socket],
            watchdogs: ManualWatchdogScheduler()
        )

        let ready = expectation(description: "session ready")
        provider.onEvent = { event in
            guard case .status(.listening) = event else { return }
            ready.fulfill()
        }
        provider.toggleVoice()
        wait(for: [ready], timeout: 1)

        for (callID, arguments) in [
            ("missing-text", #"{"mode":"status"}"#),
            ("blank-text", #"{"mode":"status","text":"  "}"#)
        ] {
            socket.push(text: toolCallEnvelope(
                callID: callID,
                name: "openclaw_agent_control",
                arguments: arguments
            ))
        }
        waitForStateQueue()
        XCTAssertEqual(socket.sentMethodCount("talk.session.steer"), 0)
        for callID in ["missing-text", "blank-text"] {
            let malformedSubmit = try XCTUnwrap(socket.sentFrames.last {
                guard $0["method"] as? String == "talk.session.submitToolResult",
                      let params = $0["params"] as? [String: Any] else {
                    return false
                }
                return params["callId"] as? String == callID
            })
            XCTAssertEqual(
                ((malformedSubmit["params"] as? [String: Any])?["result"] as? [String: Any])?["error"] as? String,
                "Malformed OpenClaw Talk tool call."
            )
        }

        socket.push(text: toolCallEnvelope(
            callID: "unknown-mode",
            name: "openclaw_agent_control",
            arguments: #"{"mode":"pause","text":"Check progress."}"#
        ))
        socket.push(text: toolCallEnvelope(
            callID: "known-mode",
            name: "openclaw_agent_control",
            arguments: #"{"mode":"followup","text":"Also inspect logs."}"#
        ))
        waitForStateQueue()

        let steerFrames = socket.sentFrames.filter {
            $0["method"] as? String == "talk.session.steer"
        }
        XCTAssertEqual(steerFrames.count, 2)
        let unknownModeParams = try XCTUnwrap(steerFrames[0]["params"] as? [String: Any])
        XCTAssertEqual(unknownModeParams["text"] as? String, "Check progress.")
        XCTAssertNil(unknownModeParams["mode"])
        XCTAssertEqual(
            Set(unknownModeParams.keys),
            ["sessionId", "sessionKey", "text"]
        )
        let knownModeParams = try XCTUnwrap(steerFrames[1]["params"] as? [String: Any])
        XCTAssertEqual(knownModeParams["mode"] as? String, "followup")

        for (index, frame) in steerFrames.enumerated() {
            socket.push(text: successfulResponse(
                id: try XCTUnwrap(frame["id"] as? String),
                payload: #"{"accepted":true,"sequence":\#(index + 1)}"#
            ))
        }
        waitForStateQueue()

        let submittedCallIDs = socket.sentFrames.compactMap { frame -> String? in
            guard frame["method"] as? String == "talk.session.submitToolResult",
                  let params = frame["params"] as? [String: Any] else {
                return nil
            }
            return params["callId"] as? String
        }
        XCTAssertTrue(submittedCallIDs.contains("unknown-mode"))
        XCTAssertTrue(submittedCallIDs.contains("known-mode"))
    }

    func testAgentControlSteerFailureSubmitsGatewayError() throws {
        let socket = ScriptedOpenClawWebSocket(messages: liveSessionMessages())
        let provider = makeProvider(
            audioEngine: LifecycleAudioEngine(),
            sockets: [socket],
            watchdogs: ManualWatchdogScheduler()
        )

        let ready = expectation(description: "session ready")
        provider.onEvent = { event in
            guard case .status(.listening) = event else { return }
            ready.fulfill()
        }
        provider.toggleVoice()
        wait(for: [ready], timeout: 1)

        socket.push(text: toolCallEnvelope(
            callID: "failed-control",
            name: "openclaw_agent_control",
            arguments: #"{"mode":"cancel","text":"Cancel it."}"#
        ))
        waitForStateQueue()
        let steerFrame = try XCTUnwrap(socket.sentFrames.last {
            $0["method"] as? String == "talk.session.steer"
        })
        socket.push(text: failedResponse(
            id: try XCTUnwrap(steerFrame["id"] as? String),
            message: "No active run."
        ))
        waitForStateQueue()

        let submitFrame = try XCTUnwrap(socket.sentFrames.last {
            guard $0["method"] as? String == "talk.session.submitToolResult",
                  let params = $0["params"] as? [String: Any] else {
                return false
            }
            return params["callId"] as? String == "failed-control"
        })
        XCTAssertEqual(
            (((submitFrame["params"] as? [String: Any])?["result"] as? [String: Any])?["error"] as? String),
            "No active run."
        )
    }

    func testUnknownToolStillSubmitsUnsupportedRejection() throws {
        let socket = ScriptedOpenClawWebSocket(messages: liveSessionMessages())
        let provider = makeProvider(
            audioEngine: LifecycleAudioEngine(),
            sockets: [socket],
            watchdogs: ManualWatchdogScheduler()
        )

        let ready = expectation(description: "session ready")
        provider.onEvent = { event in
            guard case .status(.listening) = event else { return }
            ready.fulfill()
        }
        provider.toggleVoice()
        wait(for: [ready], timeout: 1)

        let rejected = expectation(description: "unknown tool rejected")
        provider.onEvent = { event in
            guard case let .diagnostic(message) = event,
                  message.contains("rejected unsupported tool 'other_tool'") else {
                return
            }
            rejected.fulfill()
        }
        socket.push(text: toolCallEnvelope(
            callID: "unknown-call",
            name: "other_tool",
            arguments: #"{"text":"Do something."}"#
        ))
        wait(for: [rejected], timeout: 1)
        waitForStateQueue()

        XCTAssertEqual(socket.sentMethodCount("talk.session.steer"), 0)
        XCTAssertEqual(socket.sentMethodCount("talk.client.toolCall"), 0)
        let submitFrame = try XCTUnwrap(socket.sentFrames.last {
            guard $0["method"] as? String == "talk.session.submitToolResult",
                  let params = $0["params"] as? [String: Any] else {
                return false
            }
            return params["callId"] as? String == "unknown-call"
        })
        XCTAssertEqual(
            (((submitFrame["params"] as? [String: Any])?["result"] as? [String: Any])?["error"] as? String),
            "Unsupported OpenClaw Talk tool."
        )
    }

    func testConsultToolProgressResetsWatchdogAndIgnoresForeignRuns() throws {
        let socket = ScriptedOpenClawWebSocket(messages: liveSessionMessages())
        let watchdogs = ManualWatchdogScheduler()
        let provider = makeProvider(
            audioEngine: LifecycleAudioEngine(),
            sockets: [socket],
            watchdogs: watchdogs
        )

        let ready = expectation(description: "session ready")
        provider.onEvent = { event in
            guard case .status(.listening) = event else { return }
            ready.fulfill()
        }
        provider.toggleVoice()
        wait(for: [ready], timeout: 1)

        let clientRequest = expectation(description: "consult request sent")
        socket.onSentMethod = { method, count in
            if method == "talk.client.toolCall", count == 1 {
                clientRequest.fulfill()
            }
        }
        socket.push(text: toolCallEnvelope(callID: "call-progress"))
        wait(for: [clientRequest], timeout: 1)
        let clientFrame = try XCTUnwrap(socket.sentFrames.last {
            $0["method"] as? String == "talk.client.toolCall"
        })
        socket.push(text: successfulResponse(
            id: try XCTUnwrap(clientFrame["id"] as? String),
            payload: #"{"runId":"run-progress"}"#
        ))
        waitForStateQueue()
        let scheduledBeforeProgress = watchdogs.scheduledDelays.count

        let toolDiagnostic = expectation(description: "tool diagnostic")
        provider.onEvent = { event in
            if case let .diagnostic(message) = event,
               message.contains("running tool 'web_search'") {
                toolDiagnostic.fulfill()
            }
        }
        socket.push(text: #"{"type":"event","event":"agent","payload":{"runId":"run-progress","stream":"tool","data":{"phase":"start","name":"web_search"}}}"#)
        wait(for: [toolDiagnostic], timeout: 1)
        // Progress re-arms the watchdog pair (45s reassurance + 180s idle kill).
        XCTAssertEqual(
            Array(watchdogs.scheduledDelays.suffix(2)), [45, 180]
        )
        XCTAssertGreaterThan(watchdogs.scheduledDelays.count, scheduledBeforeProgress)

        // A different run's tool events must not touch our watchdog.
        let countAfterOurs = watchdogs.scheduledDelays.count
        socket.push(text: #"{"type":"event","event":"agent","payload":{"runId":"someone-else","stream":"tool","data":{"phase":"start","name":"exec"}}}"#)
        waitForStateQueue()
        XCTAssertEqual(watchdogs.scheduledDelays.count, countAfterOurs)
        withExtendedLifetime(provider) {}
    }

    func testConsultTimeoutSubmitsFailureWithoutNeedsAttention() throws {
        let socket = ScriptedOpenClawWebSocket(messages: liveSessionMessages())
        let watchdogs = ManualWatchdogScheduler()
        let provider = makeProvider(
            audioEngine: LifecycleAudioEngine(),
            sockets: [socket],
            watchdogs: watchdogs
        )

        let ready = expectation(description: "session ready")
        provider.onEvent = { event in
            guard case .status(.listening) = event else { return }
            ready.fulfill()
        }
        provider.toggleVoice()
        wait(for: [ready], timeout: 1)

        let clientRequest = expectation(description: "consult request sent")
        socket.onSentMethod = { method, count in
            if method == "talk.client.toolCall", count == 1 {
                clientRequest.fulfill()
            }
        }
        socket.push(text: toolCallEnvelope(callID: "call-timeout"))
        wait(for: [clientRequest], timeout: 1)

        let clientFrame = try XCTUnwrap(socket.sentFrames.last {
            $0["method"] as? String == "talk.client.toolCall"
        })
        socket.push(text: successfulResponse(
            id: try XCTUnwrap(clientFrame["id"] as? String),
            payload: #"{"runId":"run-timeout"}"#
        ))
        waitForStateQueue()
        // A consult schedules a 45s progress reassurance and the 180s
        // timeout watchdog (60s killed real source_answer work, 2026-07-23).
        XCTAssertEqual(Array(watchdogs.scheduledDelays.suffix(2)), [45, 180])

        let stillRunning = expectation(description: "progress diagnostic")
        let timedOut = expectation(description: "timeout diagnostic")
        let submitted = expectation(description: "timeout result submitted")
        let unexpectedAttention = expectation(description: "no attention status")
        unexpectedAttention.isInverted = true
        provider.onEvent = { event in
            switch event {
            case let .diagnostic(message) where message.contains("consult still running"):
                stillRunning.fulfill()
            case let .diagnostic(message) where message.contains("consult timed out"):
                timedOut.fulfill()
            case .status(.needsAttention):
                unexpectedAttention.fulfill()
            default:
                break
            }
        }
        socket.onSentMethod = { method, count in
            if method == "talk.session.submitToolResult", count == 1 {
                submitted.fulfill()
            }
        }
        XCTAssertTrue(watchdogs.fireNextActive())
        wait(for: [stillRunning], timeout: 1)
        XCTAssertTrue(watchdogs.fireNextActive())
        wait(for: [timedOut, submitted], timeout: 1)

        let submitFrame = try XCTUnwrap(socket.sentFrames.last {
            $0["method"] as? String == "talk.session.submitToolResult"
        })
        let submitParams = try XCTUnwrap(submitFrame["params"] as? [String: Any])
        XCTAssertEqual(submitParams["sessionId"] as? String, "session-1")
        XCTAssertEqual(submitParams["callId"] as? String, "call-timeout")
        XCTAssertEqual(
            (submitParams["result"] as? [String: Any])?["error"] as? String,
            "OpenClaw consult timed out."
        )

        let listening = expectation(description: "listening after timeout result resolves")
        provider.onEvent = { event in
            switch event {
            case .status(.listening):
                listening.fulfill()
            case .status(.needsAttention):
                unexpectedAttention.fulfill()
            default:
                break
            }
        }
        socket.push(text: successfulResponse(id: try XCTUnwrap(submitFrame["id"] as? String)))
        wait(for: [listening], timeout: 1)
        wait(for: [unexpectedAttention], timeout: 0.1)
        XCTAssertEqual(socket.cancelCount, 0)
    }

    func testMalformedToolCallEmitsDiagnosticAndKeepsSessionLive() {
        let socket = ScriptedOpenClawWebSocket(messages: liveSessionMessages())
        let provider = makeProvider(
            audioEngine: LifecycleAudioEngine(),
            sockets: [socket],
            watchdogs: ManualWatchdogScheduler()
        )

        let ready = expectation(description: "session ready")
        provider.onEvent = { event in
            guard case .status(.listening) = event else { return }
            ready.fulfill()
        }
        provider.toggleVoice()
        wait(for: [ready], timeout: 1)

        let malformed = expectation(description: "malformed diagnostic")
        let unexpectedAttention = expectation(description: "no attention status")
        unexpectedAttention.isInverted = true
        provider.onEvent = { event in
            switch event {
            case let .diagnostic(message) where message.contains("omitted its call id"):
                XCTAssertFalse(message.contains("must-not-appear"))
                malformed.fulfill()
            case .status(.needsAttention):
                unexpectedAttention.fulfill()
            default:
                break
            }
        }
        socket.push(text: """
            {"type":"event","event":"talk.event","payload":{"relaySessionId":"relay-1",\
            "type":"toolCall","name":"openclaw_agent_consult",\
            "args":{"token":"must-not-appear"}}}
            """)
        wait(for: [malformed], timeout: 1)
        wait(for: [unexpectedAttention], timeout: 0.1)

        XCTAssertEqual(socket.sentMethodCount("talk.client.toolCall"), 0)
        XCTAssertEqual(socket.sentMethodCount("talk.session.submitToolResult"), 0)
        XCTAssertEqual(socket.cancelCount, 0)
        XCTAssertEqual(socket.invalidateCount, 0)
    }

    func testOverlappingToolCallIsRejectedWithoutCorruptingActiveConsult() throws {
        let socket = ScriptedOpenClawWebSocket(messages: liveSessionMessages())
        let provider = makeProvider(
            audioEngine: LifecycleAudioEngine(),
            sockets: [socket],
            watchdogs: ManualWatchdogScheduler()
        )

        let ready = expectation(description: "session ready")
        provider.onEvent = { event in
            guard case .status(.listening) = event else { return }
            ready.fulfill()
        }
        provider.toggleVoice()
        wait(for: [ready], timeout: 1)

        socket.push(text: toolCallEnvelope(callID: "call-1"))
        waitForStateQueue()
        let firstClientFrame = try XCTUnwrap(socket.sentFrames.last {
            $0["method"] as? String == "talk.client.toolCall"
        })
        socket.push(text: successfulResponse(
            id: try XCTUnwrap(firstClientFrame["id"] as? String),
            payload: #"{"runId":"run-1"}"#
        ))
        waitForStateQueue()

        let rejected = expectation(description: "overlap rejected")
        let rejectionSubmitted = expectation(description: "overlap result submitted")
        provider.onEvent = { event in
            guard case let .diagnostic(message) = event,
                  message.contains("overlapping") else { return }
            rejected.fulfill()
        }
        socket.onSentMethod = { method, count in
            if method == "talk.session.submitToolResult", count == 1 {
                rejectionSubmitted.fulfill()
            }
        }
        socket.push(text: toolCallEnvelope(callID: "call-2"))
        wait(for: [rejected, rejectionSubmitted], timeout: 1)

        XCTAssertEqual(socket.sentMethodCount("talk.client.toolCall"), 1)
        let rejectionFrame = try XCTUnwrap(socket.sentFrames.last {
            $0["method"] as? String == "talk.session.submitToolResult"
        })
        let rejectionParams = try XCTUnwrap(rejectionFrame["params"] as? [String: Any])
        XCTAssertEqual(rejectionParams["callId"] as? String, "call-2")
        XCTAssertEqual(
            (rejectionParams["result"] as? [String: Any])?["error"] as? String,
            "Another OpenClaw consult is already in progress."
        )
        socket.push(text: successfulResponse(
            id: try XCTUnwrap(rejectionFrame["id"] as? String)
        ))
        waitForStateQueue()

        let firstSubmitted = expectation(description: "original consult result submitted")
        socket.onSentMethod = { method, count in
            if method == "talk.session.submitToolResult", count == 2 {
                firstSubmitted.fulfill()
            }
        }
        socket.push(text: chatLifecycle(
            runID: "run-1",
            state: "final",
            message: #"{"text":"Original consult completed."}"#
        ))
        wait(for: [firstSubmitted], timeout: 1)

        let firstSubmitFrame = try XCTUnwrap(socket.sentFrames.last {
            $0["method"] as? String == "talk.session.submitToolResult"
        })
        let firstSubmitParams = try XCTUnwrap(firstSubmitFrame["params"] as? [String: Any])
        XCTAssertEqual(firstSubmitParams["callId"] as? String, "call-1")
        XCTAssertEqual(
            (firstSubmitParams["result"] as? [String: Any])?["result"] as? String,
            "Original consult completed."
        )

        let listening = expectation(description: "original consult completes")
        provider.onEvent = { event in
            guard case .status(.listening) = event else { return }
            listening.fulfill()
        }
        socket.push(text: successfulResponse(
            id: try XCTUnwrap(firstSubmitFrame["id"] as? String)
        ))
        wait(for: [listening], timeout: 1)
        XCTAssertEqual(socket.cancelCount, 0)
    }

    func testVoiceConfirmationMarkerRelaysToTranscriptAndProviderResult() throws {
        let socket = ScriptedOpenClawWebSocket(messages: liveSessionMessages())
        let provider = makeProvider(
            audioEngine: LifecycleAudioEngine(),
            sockets: [socket],
            watchdogs: ManualWatchdogScheduler()
        )

        let ready = expectation(description: "session ready")
        provider.onEvent = { event in
            guard case .status(.listening) = event else { return }
            ready.fulfill()
        }
        provider.toggleVoice()
        wait(for: [ready], timeout: 1)

        socket.push(text: toolCallEnvelope(callID: "call-confirm"))
        waitForStateQueue()
        let clientFrame = try XCTUnwrap(socket.sentFrames.last {
            $0["method"] as? String == "talk.client.toolCall"
        })
        socket.push(text: successfulResponse(
            id: try XCTUnwrap(clientFrame["id"] as? String),
            payload: #"{"runId":"run-confirm"}"#
        ))
        waitForStateQueue()

        let transcript = expectation(description: "confirmation transcript")
        let diagnostic = expectation(description: "confirmation diagnostic")
        provider.onEvent = { event in
            switch event {
            case .transcript("VOICE_CONFIRMATION_REQUIRED:confirm-123"):
                transcript.fulfill()
            case let .diagnostic(message) where message.contains("requires voice confirmation"):
                diagnostic.fulfill()
            default:
                break
            }
        }
        socket.push(text: chatLifecycle(
            runID: "run-confirm",
            state: "final",
            message: #"{"text":"VOICE_CONFIRMATION_REQUIRED:confirm-123"}"#
        ))
        wait(for: [transcript, diagnostic], timeout: 1)
        waitForStateQueue()

        let submitFrame = try XCTUnwrap(socket.sentFrames.last {
            $0["method"] as? String == "talk.session.submitToolResult"
        })
        let submitParams = try XCTUnwrap(submitFrame["params"] as? [String: Any])
        XCTAssertEqual(
            (submitParams["result"] as? [String: Any])?["result"] as? String,
            "VOICE_CONFIRMATION_REQUIRED:confirm-123"
        )
    }

    private func makeProvider(
        audioEngine: LifecycleAudioEngine,
        sockets: [ScriptedOpenClawWebSocket],
        watchdogs: ManualWatchdogScheduler,
        deviceCredentials: OpenClawDeviceCredentials? = nil
    ) -> OpenClawTalkProvider {
        makeProvider(
            audioEngine: audioEngine,
            socketFactory: ScriptedOpenClawWebSocketFactory(sockets: sockets),
            watchdogs: watchdogs,
            deviceCredentials: deviceCredentials
        )
    }

    private func makeProvider(
        audioEngine: LifecycleAudioEngine,
        socketFactory: ScriptedOpenClawWebSocketFactory,
        watchdogs: ManualWatchdogScheduler,
        deviceCredentials: OpenClawDeviceCredentials? = nil
    ) -> OpenClawTalkProvider {
        OpenClawTalkProvider(
            configuration: VoiceSessionConfiguration(
                providerID: .openClaw,
                model: "",
                voice: "",
                instructions: "",
                endpointURL: ""
            ),
            tokenProvider: { "gateway-token" },
            audioEngine: audioEngine,
            deviceCredentialsProvider: { deviceCredentials },
            webSocketFactory: { socketFactory.makeSocket(request: $0) },
            watchdogScheduler: { delay, action in
                watchdogs.schedule(after: delay, action: action)
            }
        )
    }

    private var deviceCredentials: OpenClawDeviceCredentials {
        OpenClawDeviceCredentials(
            deviceID: "device-1",
            publicKey: Data(repeating: 0x11, count: 32),
            privateKeySeed: Data(repeating: 0x22, count: 32),
            operatorToken: "device-token",
            operatorScopes: ["operator.talk", "operator.write"]
        )
    }

    private func liveSessionMessages() -> [String] {
        [
            #"{"type":"event","event":"connect.challenge","payload":{"nonce":"nonce-1","ts":1}}"#,
            #"{"type":"res","id":"1","ok":true,"payload":{"type":"hello-ok","protocol":4}}"#,
            #"{"type":"res","id":"2","ok":true,"payload":{"sessionId":"session-1","relaySessionId":"relay-1"}}"#,
            #"{"type":"event","event":"talk.event","payload":{"relaySessionId":"relay-1","type":"ready"}}"#
        ]
    }

    private func audioEnvelope(byte: UInt8) -> String {
        let audio = Data([byte]).base64EncodedString()
        return """
            {"type":"event","event":"talk.event","payload":{"relaySessionId":"relay-1",\
            "type":"audio","audioBase64":"\(audio)"}}
            """
    }

    private func userTranscriptDelta() -> String {
        """
        {"type":"event","event":"talk.event","payload":{"relaySessionId":"relay-1",\
        "type":"transcript","role":"user","text":"hel","final":false,\
        "talkEvent":{"type":"transcript.delta","payload":{"role":"user","text":"hel"}}}}
        """
    }

    private func audioDoneEnvelope() -> String {
        """
        {"type":"event","event":"talk.event","payload":{"relaySessionId":"relay-1",\
        "type":"audioDone"}}
        """
    }

    private func toolCallEnvelope(
        callID: String,
        name: String = "openclaw_agent_consult",
        arguments: String = #"{"question":"What now?"}"#
    ) -> String {
        """
        {"type":"event","event":"talk.event","payload":{"relaySessionId":"relay-1",\
        "type":"toolCall","callId":"\(callID)","name":"\(name)",\
        "args":\(arguments)}}
        """
    }

    private func successfulResponse(id: String, payload: String = #"{"ok":true}"#) -> String {
        #"{"type":"res","id":"\#(id)","ok":true,"payload":\#(payload)}"#
    }

    private func failedResponse(id: String, message: String) -> String {
        """
        {"type":"res","id":"\(id)","ok":false,\
        "error":{"code":"agent-control-failed","message":"\(message)"}}
        """
    }

    private func chatLifecycle(runID: String, state: String, message: String? = nil) -> String {
        let messageField = message.map { #","message":\#($0)"# } ?? ""
        return """
            {"type":"event","event":"chat","payload":{"runId":"\(runID)",\
            "state":"\(state)"\(messageField)}}
            """
    }

    private func waitForStateQueue() {
        let settled = expectation(description: "state queue settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            settled.fulfill()
        }
        wait(for: [settled], timeout: 1)
    }
}

private final class ScriptedOpenClawWebSocketFactory {
    private let lock = NSLock()
    private var sockets: [ScriptedOpenClawWebSocket]
    private var requests: [URL] = []

    init(sockets: [ScriptedOpenClawWebSocket]) {
        self.sockets = sockets
    }

    var requestedURLs: [URL] {
        lock.withLock { requests }
    }

    func makeSocket(request: URLRequest) -> OpenClawTalkWebSocket {
        lock.withLock {
            if let url = request.url {
                requests.append(url)
            }
            return sockets.removeFirst()
        }
    }
}

private final class ScriptedOpenClawWebSocket: OpenClawTalkWebSocket {
    var onOpen: (() -> Void)?
    var onClose: ((URLSessionWebSocketTask.CloseCode) -> Void)?
    var onSentMethod: ((String, Int) -> Void)?

    private let lock = NSLock()
    private var queuedMessages: [URLSessionWebSocketTask.Message]
    private var receiveCompletion: ((
        Result<URLSessionWebSocketTask.Message, Error>
    ) -> Void)?
    private var frames: [[String: Any]] = []
    private var deferredSendCompletion: ((Error?) -> Void)?
    private let deferredCompletionMethod: String?
    private var _cancelCount = 0
    private var _invalidateCount = 0

    init(
        messages: [String] = [],
        deferredCompletionMethod: String? = nil
    ) {
        queuedMessages = messages.map(URLSessionWebSocketTask.Message.string)
        self.deferredCompletionMethod = deferredCompletionMethod
    }

    var sentFrames: [[String: Any]] {
        lock.withLock { frames }
    }

    var sentMethods: [String] {
        lock.withLock { frames.compactMap { $0["method"] as? String } }
    }

    var cancelCount: Int {
        lock.withLock { _cancelCount }
    }

    var invalidateCount: Int {
        lock.withLock { _invalidateCount }
    }

    func sentMethodCount(_ method: String) -> Int {
        lock.withLock {
            frames.filter { $0["method"] as? String == method }.count
        }
    }

    func resume() {
        onOpen?()
    }

    func receive(
        completionHandler: @escaping (Result<URLSessionWebSocketTask.Message, Error>) -> Void
    ) {
        let message = lock.withLock { () -> URLSessionWebSocketTask.Message? in
            if queuedMessages.isEmpty {
                receiveCompletion = completionHandler
                return nil
            }
            return queuedMessages.removeFirst()
        }
        if let message {
            completionHandler(.success(message))
        }
    }

    func send(
        _ message: URLSessionWebSocketTask.Message,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let result = lock.withLock { () -> (String?, Int, Bool) in
            guard case let .string(text) = message,
                  let data = text.data(using: .utf8),
                  let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return (nil, 0, false)
            }
            frames.append(frame)
            let method = frame["method"] as? String
            let count = frames.filter { $0["method"] as? String == method }.count
            if method == deferredCompletionMethod {
                deferredSendCompletion = completionHandler
                return (method, count, true)
            }
            return (method, count, false)
        }

        if let method = result.0 {
            onSentMethod?(method, result.1)
        }
        if result.2 == false {
            completionHandler(nil)
        }
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.withLock {
            _cancelCount += 1
        }
    }

    func invalidateAndCancel() {
        lock.withLock {
            _invalidateCount += 1
        }
    }

    func push(text: String) {
        let message = URLSessionWebSocketTask.Message.string(text)
        let completion = lock.withLock { () -> ((
            Result<URLSessionWebSocketTask.Message, Error>
        ) -> Void)? in
            if let receiveCompletion {
                self.receiveCompletion = nil
                return receiveCompletion
            }
            queuedMessages.append(message)
            return nil
        }
        completion?(.success(message))
    }

    func completeDeferredSend(with error: Error?) {
        let completion = lock.withLock { () -> ((Error?) -> Void)? in
            defer { deferredSendCompletion = nil }
            return deferredSendCompletion
        }
        completion?(error)
    }
}

private final class LifecycleAudioEngine: RealtimeAudioEngineProtocol {
    private let lock = NSLock()
    private var activityHandler: ((RealtimeAudioInputActivity) -> Void)?
    private var fatalFailureHandler: (() -> Void)?
    private var _startCount = 0
    private var _stopCount = 0

    var startCount: Int {
        lock.withLock { _startCount }
    }

    var stopCount: Int {
        lock.withLock { _stopCount }
    }

    func setFatalFailureHandler(_ handler: (() -> Void)?) {
        lock.withLock {
            fatalFailureHandler = handler
        }
    }

    func requestMicrophoneAccess(_ completion: @escaping (Bool) -> Void) {
        completion(true)
    }

    func start(
        inputHandler: @escaping (Data) -> Void,
        activityHandler: @escaping (RealtimeAudioInputActivity) -> Void
    ) throws {
        lock.withLock {
            _startCount += 1
            self.activityHandler = activityHandler
        }
    }

    func stop() {
        lock.withLock {
            _stopCount += 1
            activityHandler = nil
        }
    }

    func stopPlayback() {}

    func playPCM16(_ data: Data) {}

    func emitActivity(peak: Float) {
        let handler = lock.withLock { activityHandler }
        handler?(RealtimeAudioInputActivity(rms: peak, peak: peak))
    }

    func triggerFatalFailure() {
        let handler = lock.withLock { fatalFailureHandler }
        handler?()
    }
}

private final class ManualWatchdogScheduler {
    private let lock = NSLock()
    private var tasks: [ManualWatchdogTask] = []
    private var delays: [TimeInterval] = []

    var scheduledDelays: [TimeInterval] {
        lock.withLock { delays }
    }

    func schedule(
        after delay: TimeInterval,
        action: @escaping () -> Void
    ) -> OpenClawTalkWatchdogCancellation {
        let task = ManualWatchdogTask(action: action)
        lock.withLock {
            tasks.append(task)
            delays.append(delay)
        }
        return task
    }

    func fireNextActive() -> Bool {
        let task = lock.withLock {
            tasks.first { $0.isCancelled == false && $0.hasFired == false }
        }
        task?.fire()
        return task != nil
    }
}

private final class ManualWatchdogTask: OpenClawTalkWatchdogCancellation {
    private let lock = NSLock()
    private let action: () -> Void
    private var cancelled = false
    private var fired = false

    init(action: @escaping () -> Void) {
        self.action = action
    }

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    var hasFired: Bool {
        lock.withLock { fired }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
        }
    }

    func fire() {
        let shouldFire = lock.withLock { () -> Bool in
            guard cancelled == false, fired == false else { return false }
            fired = true
            return true
        }
        if shouldFire {
            action()
        }
    }
}

private enum LifecycleTestError: LocalizedError {
    case sendFailed

    var errorDescription: String? {
        "late send failure"
    }
}

private extension NSLock {
    func withLock<T>(_ action: () -> T) -> T {
        lock()
        defer { unlock() }
        return action()
    }
}
