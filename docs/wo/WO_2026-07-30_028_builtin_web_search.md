# WO-W — Web search that works the moment someone adds their OpenAI key

Date: 2026-07-30. Owner: CTO session. Engine: Codex gpt-5.6-sol.
Branch `builtin-search`.

## Problem

Web search on the OpenAI channel is broken, and the design could never have
worked for anyone but the first few users.

VoiceKey hardcodes Exa's **anonymous** MCP endpoint for every OpenAI channel
(`OpenAIRealtimeRequestBuilder.swift:198-206`). OpenAI executes MCP servers
server-side, so every VoiceKey user in the world shares one anonymous Exa
bucket. It is now exhausted:

```
response.mcp_call.failed
error: { "code": 429, "type": "http_error",
  "message": "You've hit Exa's free MCP rate limit. To continue using without
   limits, create your own Exa API key." }
```

The owner's requirement: someone who downloads VoiceKey and adds an OpenAI key
should get working web search with **no second signup, no extra account, and no
configuration**.

## Verified facts — probed live 2026-07-30, do not re-investigate

1. **The Realtime API accepts only `function` and `mcp` tool types.** Probed all
   three plausible hosted-search spellings; each was rejected with:
   `Invalid value: 'web_search'. Supported values are: 'function' and 'mcp'.`
   There is no hosted OpenAI search tool available inside a Realtime session.
2. **The same key CAN search through the Responses API.** `POST /v1/responses`
   with `tools:[{"type":"web_search"}]` returns
   `output: [web_search_call, web_search_call, message]`, status `completed`,
   and a current, correct answer.
3. **Model latency, one sample each, same query:**
   `gpt-4.1-mini` 2.8s · `gpt-5.1` 3.0s · `gpt-5-mini` 9.7s ·
   `gpt-5.1-mini` does not exist. Prefer `gpt-4.1-mini`; it is the cheapest and
   was the fastest measured.
4. **The client-side function round trip works end to end.** Declaring
   `{type: "function", name: "search_web", parameters: {query: string}}` in
   `session.update`, the model emits `response.function_call_arguments.done`
   carrying `call_id` and `arguments`. Replying with
   `conversation.item.create` `{type: "function_call_output", call_id, output}`
   followed by `response.create` makes the model speak the result. Confirmed
   live: it called `search_web` with `{"query":"Hacker News top story right
   now"}` and then spoke the answer supplied.
5. `webSearchEnabled` exists on `VoiceProfile`, is persisted, and has an apply
   case at `SettingsWindowController.swift:1722` — but **no UI control sets it
   and no code reads it.** It is currently inert in both directions.
6. Custom MCP servers are already inside the Advanced disclosure
   (`advancedMCPContainer`), with per-server authorization tokens in the
   keychain and `authorization` already sent by the request builder.

## Owner's rulings (2026-07-30, decided)

- Use the built-in search. *"Let's use this built-in web search, which we should
  have been using from the beginning."*
- *"It should be smart enough to use whichever web search is required... If it's
  cheap and fast, do it."*
- *"Let's move all of the extra web stuff into the Advanced panel in Settings."*
- The former rule that VoiceKey never executes tools itself has been **retired**
  (AGENTS.md, commit 5d43062). Local execution is a normal option now. What
  still holds: no VoiceKey backend, no VoiceKey-owned credentials — the user's
  own key does the work.

## Required behaviour

1. **Built-in search, on by default, zero configuration.** An OpenAI channel
   declares a `search_web` function tool. When the model calls it, VoiceKey
   performs a Responses API request with `tools:[{"type":"web_search"}]` using
   **the channel's own OpenAI key**, and returns the assistant text as the
   function output. Default search model `gpt-4.1-mini`.
2. **Delete the hardcoded anonymous Exa tool.** It cannot work and must not
   silently degrade the session.
3. **Make `webSearchEnabled` real, in both directions.** It gates whether the
   `search_web` tool is declared, and it gets a visible control. Default ON for
   new and existing channels — nobody should have to switch search on. Existing
   profiles that decoded `false` from an older build must not be silently
   flipped; state what you chose and why.
4. **The failure path must be honest and must not strand the turn.** If the
   search request fails (no key, network, rate limit, HTTP error), return a
   short plain-language failure as the function output so the model can say so,
   and log a diagnostic. Never leave the model waiting for a result that never
   arrives.
5. **Advanced holds the extra web machinery.** Custom MCP servers stay in the
   Advanced disclosure. The everyday control (search on/off) belongs in the
   main channel form, not behind Advanced — it is the capability, not the
   plumbing.
6. **Log what makes this diagnosable.** A search call should log that it
   happened and its outcome category. Log the query **only if** you are certain
   it cannot contain a credential — prefer logging a length or nothing. Log the
   tool count returned by any MCP listing, which is the fact whose absence made
   the original failure undiagnosable.

## Hard constraints

- **Never log the API key, the full endpoint, or search result content.** The
  session log is written to be pasteable into a public bug report and tests
  enforce it.
- The Responses call must not block the audio path or the main thread.
- A search that hangs must not hang the voice session — bound it, and return a
  failure output when the bound is hit.
- Keep the existing per-channel MCP server support working exactly as it does.

## Tests

- The Realtime session declares `search_web` when enabled, and does not when
  disabled.
- No request ever contains the Exa server URL.
- A function call is answered with `function_call_output` carrying the same
  `call_id`, followed by `response.create`.
- Search failure produces a function output the model can speak, not silence,
  and never throws into the session.
- Sentinel: an API key planted in the search path appears in no log line.
- The search HTTP layer is behind a protocol with a fake; **no test performs a
  real network call.**

## Acceptance

1. `swift build && swift test` green. If your sandbox cannot run the full
   suite, say so plainly and name what you did run.
2. A fresh channel with only an OpenAI key can search, with nothing else set.
3. `webSearchEnabled` demonstrably gates the tool, and has a control.
4. No Exa reference remains outside the Advanced custom-MCP path.

## Standing rules

Small commits on `builtin-search`. Do NOT push, merge, rebase or switch
branches. Commit this work-order file with your change. Tests must not use
`Thread.sleep` or a fixed `RunLoop.run`; poll with `waitUntil`. `UserDefaults`
suites come from `makeTestDefaults()`. Assertions must not depend on screen
size, font metrics, timing, network or installed apps. No AI co-author
trailers. You may SKIP a leg whose prerequisite is not met, and FLAG why.
