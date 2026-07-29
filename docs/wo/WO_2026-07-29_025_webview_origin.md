# WO-T — The webview must not grant the microphone on a substring match

Date: 2026-07-29. Owner: CTO session. Engine: Codex gpt-5.6-sol.
Branch `webview-origin`. Found by adversarial review, verified by the CTO
session against source.

## Problem — verified, do not re-investigate

`WebWindowController.swift:186-193`:

```swift
if origin.host.contains("chatgpt.com") || origin.host.contains("openai.com") {
    onDiagnostic?("Granting microphone capture permission for \(origin.host)")
    decisionHandler(.grant)
} else {
    decisionHandler(.prompt)
}
```

`contains` is a substring test, so `openai.com.attacker.example`,
`notopenai.com` and `chatgpt.com.evil.test` all match and are granted the
microphone with no prompt. `webView(_:decidePolicyFor:decisionHandler:)` in the
same file ends with `decisionHandler(.allow)`, so navigation to such a host is
not itself blocked.

The ChatGPT web channel is currently parked, which limits exposure today. It is
still shipped code holding a microphone-grant decision.

## Required behaviour

1. Grant automatically **only** for an exact host match against a small
   allowlist, or a true subdomain of one (`foo.chatgpt.com` yes,
   `chatgpt.com.attacker.example` no, `notchatgpt.com` no). A suffix test alone
   is not sufficient — it must be anchored on a dot boundary.
2. Everything else keeps the existing `.prompt` behaviour. Do not switch it to
   `.deny`; that changes product behaviour beyond this fix.
3. Case-insensitive comparison; hosts are case-insensitive.
4. Put the decision in a **pure, testable function** (host string in, decision
   out) rather than inline in the delegate, so it can be tested without a
   `WKSecurityOrigin`. The codebase's `*Policy` types are the house pattern.
5. The diagnostic line may name the host. It must not carry a full URL.

## Tests

Table-driven over at least: `chatgpt.com`, `openai.com`, `auth.openai.com`,
`chat.chatgpt.com` (all granted); `openai.com.attacker.example`,
`chatgpt.com.evil.test`, `notopenai.com`, `myopenai.com.co`, `openai.company`,
`evil.com/openai.com`, empty host, and a mixed-case variant of a legitimate host
(all not granted). **At least one attacker case must fail against the current
code** — confirm that and say so in your summary.

## Acceptance

1. `swift build && swift test` green.
2. The grant decision is reachable in tests without constructing a WKWebView.
3. No behaviour change for legitimate ChatGPT/OpenAI hosts.

## Standing rules

Small commits on `webview-origin`. Do NOT push, merge, or switch branches. Never
log a secret or a full URL. No `Thread.sleep` in tests. Assertions must not
depend on screen size, font metrics or timing. No AI co-author trailers.
You may SKIP a leg whose prerequisite is not met, and FLAG why.
