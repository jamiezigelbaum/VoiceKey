# ChatGPT web channel (GPT-Live): PARKED 2026-07-24

Decision (Jamie): stop engineering this channel; revisit when the GPT-Live
API ships. Daily drivers are the OpenAI Realtime API channel and Castor.

## What works
- Login (email+password; Google OAuth blocked for passkey-only accounts —
  WebAuthn is unavailable to embedded webviews by Apple's security model).
- Session persistence across rebuilds (default WKWebsiteDataStore).
- Per-host user agents: Safari UA for chatgpt.com (required or the served
  page strips GPT-Live server tools), default WebKit UA for Google auth.
- DOM probe finds the 2026 GPT-Live UI ("Start Voice" reuses the
  composer-speech-button testid; login detection keys on auth-shell
  markers). Control inventory + media-state instrumentation log evidence
  to the session log on every failure.
- Native-click machinery with stable Developer ID dev-build signing
  (TCC grants survive rebuilds) and prompted accessibility trust.

## The dead end (chronological diagnosis, all evidence in
## session-2026-07-24.log)
1. Synthetic DOM click: opens a text thread titled "Voice duplex system",
   media pipeline refused (audio elements paused, readyState 0, no
   srcObject, page visible).
2. In-window WebKit event fallback (no AX trust): same.
3. REAL CGEvent click with granted accessibility trust (12:25Z run — no
   trust-fallback line, click at correct screen coords): STILL no media.
   GPT-Live's voice session does not start in a WKWebView even with an
   OS-level gesture. The remaining gate is inside WebKit/GPT-Live
   (user-activation provenance, WebRTC/AudioWorklet requirements, or
   deliberate embed detection) — beyond client reach.

## Revisit triggers
- GPT-Live API ships (OpenAI said "soon", July 2026) → integrate as a
  first-class Realtime-style provider; all the probe/webview machinery
  becomes unnecessary for voice.
- "Sign in with ChatGPT" third-party program opens → sanctioned
  subscription auth without the webview.

## Related research (in session records)
- Passkeys/WebAuthn in embedded webviews: only real browsers with Apple's
  com.apple.developer.web-browser.public-key-credential entitlement get
  them; Developer ID viable (Chrome/Brave verified) but requires passing
  Apple's "is a browser" review.
