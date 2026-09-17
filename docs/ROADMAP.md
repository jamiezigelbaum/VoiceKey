# Roadmap

Planned work, in rough order. Each item has a GitHub issue under the
matching milestone; this file is the narrative, the issues are the tracker.

## v0.4 — GPT-Live and a pluggable backend

OpenAI's `gpt-live-1` (in the API since 2026-09-10) is a different
architecture from `gpt-realtime`: a full-duplex voice-only model, billed per
minute, that delegates all reasoning to a backend. The backend is either an
OpenAI Responses model or, with *client delegation*, anything the client
runs. That second mode is the interesting one for VoiceKey, because it makes
the voice layer independent of which agent is doing the thinking.

1. **GPT-Live provider.** A new provider alongside OpenAI Realtime, not a
   replacement. New endpoint (`/v1/live/sessions`), new event names
   (`session.input_audio.append`, `session.output_audio.delta`,
   `session.delegation.created`, `session.commentary.append`, …), continuous
   audio with no manual turn control. Reuses the audio engine, PCM codec,
   keychain, and session log. Must be validated against the real endpoint
   before anything is asserted in tests.
2. **Pluggable delegation backend.** With client delegation VoiceKey owns the
   voice session and, when GPT-Live asks for backend work, sends the
   transcript to a backend over HTTP and streams the answer back for the
   model to speak. Backends:
   - OpenAI Responses (built in; GPT-5.6 Terra or Luna, with functions and
     web search).
   - Any OpenAI-compatible endpoint, configured with a URL and key: Hermes
     Agent, LiteLLM, Ollama, and most agent harnesses. Hermes' `/v1/responses`
     with `previous_response_id` gives conversation continuity for free.
   - OpenClaw stays on its native Talk path.
   Open design question: the delegation event carries no task text, so the
   client reconstructs the request from the transcript stream.
3. **Make GPT-Live the default for new OpenAI channels** once (1) and (2)
   are validated, keeping Realtime selectable. Realtime still has one thing
   GPT-Live's built-in delegation does not list: remote MCP servers.
4. **OpenClaw on GPT-Live.** OpenClaw added native GPT-Live support to Talk
   in 2026.9 (after 2026.9.4). Verify VoiceKey's `talk.session.*` relay path
   against a gateway running it, and adjust if the event shapes moved.

## Later

- Gemini Live and Deepgram Voice Agent adapters (the provider slots exist).
- Submit the cask to the main Homebrew Cask repository once there is enough
  usage.
- Retire the ChatGPT (web) provider if GPT-Live in the API makes it
  redundant.

## Done

- 0.3.0: public repository, `gpt-realtime-2.1` default, generic dev signing.
