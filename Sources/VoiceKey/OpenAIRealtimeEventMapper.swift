import Foundation

enum OpenAIRealtimeEventAction: Equatable {
    case providerEvent(VoiceProviderEvent)
    case sessionUpdated
    case responseStarted
    case responseEnded
    case assistantMessageStarted(itemID: String)
    case webSearchFunctionCall(callID: String, arguments: String)
    /// The server finished sending audio. Playback usually continues for
    /// seconds afterwards, so this is deliberately NOT "back to listening".
    case assistantAudioComplete
    case mcpCallTerminated
    case stopPlayback
    case audio(Data)
}

enum OpenAIRealtimeEventMapper {
    static func actions(from text: String) -> [OpenAIRealtimeEventAction] {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return []
        }

        if type.hasPrefix("mcp_list_tools.") || type.hasPrefix("response.mcp_call.") {
            let diagnostic = VoiceProviderEvent.diagnostic(
                mcpDiagnostic(type: type, object: object)
            )
            if type == "response.mcp_call.in_progress" {
                return [
                    .providerEvent(diagnostic),
                    .providerEvent(.status(.thinking))
                ]
            }
            if type == "response.mcp_call.completed"
                || type == "response.mcp_call.failed" {
                return [
                    .providerEvent(diagnostic),
                    .mcpCallTerminated
                ]
            }
            return [.providerEvent(diagnostic)]
        }

        switch type {
        case "session.created":
            return [.providerEvent(.diagnostic(type))]
        case "session.updated":
            return [
                .providerEvent(.diagnostic(type)),
                .sessionUpdated
            ]
        case "input_audio_buffer.speech_started":
            return [
                .stopPlayback,
                .providerEvent(.status(.listening))
            ]
        case "input_audio_buffer.speech_stopped", "input_audio_buffer.committed":
            return [.providerEvent(.status(.thinking))]
        case "response.created":
            return [
                .providerEvent(.status(.thinking)),
                .responseStarted
            ]
        case "response.output_item.added":
            guard let item = object["item"] as? [String: Any],
                  item["type"] as? String == "message",
                  let itemID = item["id"] as? String else {
                return [.providerEvent(.diagnostic(type))]
            }
            return [
                .assistantMessageStarted(itemID: itemID),
                .providerEvent(.diagnostic(type))
            ]
        case "response.function_call_arguments.done":
            guard let callID = object["call_id"] as? String,
                  let arguments = object["arguments"] as? String else {
                return [.providerEvent(.diagnostic(type))]
            }
            return [
                .providerEvent(.diagnostic(type)),
                .webSearchFunctionCall(
                    callID: callID,
                    arguments: arguments
                )
            ]
        case "response.output_audio.delta", "response.audio.delta":
            guard let delta = object["delta"] as? String,
                  let audio = Data(base64Encoded: delta) else {
                return []
            }
            return [
                .audio(audio),
                .providerEvent(.status(.speaking))
            ]
        case "response.output_audio_transcript.delta", "response.audio_transcript.delta", "response.output_text.delta":
            guard let delta = object["delta"] as? String else { return [] }
            return [.providerEvent(.transcript(delta))]
        case "response.output_audio.done", "response.audio.done":
            return [.assistantAudioComplete]
        case "response.done":
            return [
                .assistantAudioComplete,
                .responseEnded
            ]
        case "error":
            let message = ((object["error"] as? [String: Any])?["message"] as? String)
                ?? "OpenAI Realtime returned an error."
            return [.providerEvent(.status(.needsAttention(message)))]
        default:
            return [.providerEvent(.diagnostic(type))]
        }
    }

    private static func mcpDiagnostic(type: String, object: [String: Any]) -> String {
        let nestedObjects = ["item", "call", "mcp_call"].compactMap {
            object[$0] as? [String: Any]
        }
        let objects = [object] + nestedObjects
        let serverLabel = firstString(
            keys: ["server_label", "serverLabel"],
            objects: objects
        )
        let toolNames = toolNames(in: objects)
        let toolName = firstString(
            keys: ["name", "tool_name", "toolName"],
            objects: objects
        ) ?? toolNames.first

        var details: [String] = []
        if let serverLabel { details.append("server: \(serverLabel)") }
        if type == "mcp_list_tools.completed" {
            details.append(
                "tool count: \(toolCount(in: objects) ?? 0)"
            )
        }
        if let toolName { details.append("tool: \(toolName)") }
        guard details.isEmpty == false else { return "MCP \(type)." }
        return "MCP \(type) — \(details.joined(separator: "; "))."
    }

    private static func firstString(
        keys: [String],
        objects: [[String: Any]]
    ) -> String? {
        for object in objects {
            for key in keys {
                if let value = object[key] as? String, value.isEmpty == false {
                    return value
                }
            }
        }
        return nil
    }

    private static func toolNames(in objects: [[String: Any]]) -> [String] {
        for object in objects {
            guard let tools = object["tools"] as? [[String: Any]] else { continue }
            let names = tools.compactMap { $0["name"] as? String }
            if names.isEmpty == false {
                return names
            }
        }
        return []
    }

    private static func toolCount(
        in objects: [[String: Any]]
    ) -> Int? {
        for object in objects {
            if let tools = object["tools"] as? [[String: Any]] {
                return tools.count
            }
        }
        return nil
    }
}
