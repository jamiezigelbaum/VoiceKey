# VoiceKey

VoiceKey is a tiny macOS menu bar app for one-key access to web-based AI voice
experiences without keeping a browser window open.

The first provider is ChatGPT Voice on `chatgpt.com`. Claude Web is planned as
the next provider once the app shell and trusted-click bridge are solid.

## Goals

- Self-contained native macOS menu bar app.
- No Hammerspoon, browser extension, Electron, or third-party package manager.
- App-owned login/session through an embedded web view.
- App-owned global hotkey.
- App-owned microphone permission.
- Browser-free day-to-day workflow after first setup.

## Current Status

This is an early native Swift/AppKit app with:

- menu bar controls
- F16 global hotkey
- persistent `WKWebView` session for `chatgpt.com`
- WebKit microphone permission hook
- DOM-to-native-click bridge for ChatGPT Voice controls
- visible provider status for loading, sign-in required, ready, starting, active,
  stopping, and needs-attention states
- fixture-tested DOM probes that distinguish ChatGPT Voice Mode from text
  dictation controls

The next milestone is live testing against ChatGPT's current web UI after
sign-in, especially first-run voice selection, microphone prompts, and end-call
behavior.

## Build

```zsh
swift build
```

To build an app bundle:

```zsh
./scripts/build-app.zsh
open .build/VoiceKey.app
```

## Setup

1. Launch VoiceKey.
2. Choose `Show ChatGPT` from the menu bar item.
3. Sign in to ChatGPT in the VoiceKey window.
4. Grant microphone permission when prompted.
5. Press `F16` to toggle ChatGPT Voice.

The menu shows the currently assigned voice hotkey next to the start/stop
command. In this build the default is `F16`.

If ChatGPT appears to hear phrases you did not say, change macOS audio output to
headphones or another output path that the microphone cannot hear. VoiceKey
sends one start click per F16 press; repeated phantom turns are usually speaker
audio feeding back into the microphone.

## Architecture

VoiceKey is intentionally small:

- `VoiceKeyAppDelegate`: menu bar and hotkey lifecycle.
- `GlobalHotKey`: Carbon `RegisterEventHotKey` wrapper.
- `WebWindowController`: persistent `WKWebView`, mic permission, native click bridge.
- `ChatGPTProvider`: provider-specific status, retry, and start/stop behavior.
- `ChatGPTDOMProbe`: ChatGPT DOM selectors shared by the app and fixture tests.

Provider support should stay behind a simple shape:

```text
prepare()
show()
toggleVoice()
startVoice()
stopVoice()
```

## Notes

VoiceKey does not handle OpenAI passwords, OAuth tokens, or session cookies
directly. Authentication happens through the provider's normal web login inside
the app's web view. The web session is persisted by WebKit.

VoiceKey automates a human-facing web UI. It should not bypass provider limits,
spoof private APIs, or run unattended conversations.
