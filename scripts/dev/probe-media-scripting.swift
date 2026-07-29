#!/usr/bin/env swift
//
// Ground-truth probe for WO-R (pause other media while a voice channel is
// active). Answers three questions VoiceKey's implementation depends on, and
// answers them without ever changing anyone's playback.
//
//   1. Does NSAppleScript compile and execute on a background serial queue?
//      (The pause must not run on the main thread — it sits in front of the
//      audio graph, and nothing may delay a voice session.)
//   2. Do VoiceKey's actual script sources compile against the real
//      terminology of Music and Spotify?
//   3. Does compiling a `tell application "X"` script launch X?
//
// SAFE BY CONSTRUCTION: the only script this ever *executes* is arithmetic
// with no `tell`. The player scripts are compiled and thrown away, so no
// Apple Event carrying pause or play is ever sent.
//
//   swift scripts/dev/probe-media-scripting.swift
//
// Findings, 2026-07-29 on Xanthos (macOS 15, Music running, Spotify not):
//   - background compile+execute: works, twice in a row on the same queue.
//   - all six sources compile: true, for both players.
//   - compiling the Spotify sources did NOT launch Spotify.
//   - NSRunningApplication answers the running question with no Apple Event.

import AppKit
import Foundation

func stateSource(_ app: String) -> String {
    """
    if application "\(app)" is running then
        tell application "\(app)"
            set currentState to player state
            if currentState is playing then return "playing"
            if currentState is paused then return "paused"
            return "stopped"
        end tell
    end if
    return "notrunning"
    """
}

func transportSource(_ app: String, _ command: String) -> String {
    """
    if application "\(app)" is running then
        tell application "\(app)" to \(command)
    end if
    return "ok"
    """
}

func isRunning(_ bundleID: String) -> Bool {
    NSRunningApplication
        .runningApplications(withBundleIdentifier: bundleID)
        .isEmpty == false
}

// 1. NSAppleScript off the main thread, with a script that sends no events.
print("== 1. NSAppleScript on a background serial queue ==")
let queue = DispatchQueue(label: "probe.media-scripting")
for attempt in 1...2 {
    let done = DispatchSemaphore(value: 0)
    var line = "no result"
    queue.async {
        let where_ = Thread.isMainThread ? "MAIN" : "background"
        var error: NSDictionary?
        let script = NSAppleScript(source: "return \"ok-\" & (2 + 3)")
        let compiled = script?.compileAndReturnError(&error) ?? false
        let result = script?.executeAndReturnError(&error)
        line = "attempt \(attempt) on \(where_): compiled=\(compiled) "
            + "result=\(result?.stringValue ?? "nil") "
            + "error=\(error.map { "\($0)" } ?? "none")"
        done.signal()
    }
    _ = done.wait(timeout: .now() + 20)
    print(line)
}

// 2 + 3. Compile only. Never executed, so nothing reaches a player.
print("\n== 2. running state before compiling ==")
let players = [("Music", "com.apple.Music"), ("Spotify", "com.spotify.client")]
for (name, bundleID) in players {
    print("NSRunningApplication \(bundleID) (\(name)): \(isRunning(bundleID))")
}

print("\n== 3. compile VoiceKey's real sources ==")
for (name, _) in players {
    for (label, source) in [
        ("state", stateSource(name)),
        ("pause", transportSource(name, "pause")),
        ("play", transportSource(name, "play"))
    ] {
        var error: NSDictionary?
        let compiled = NSAppleScript(source: source)?
            .compileAndReturnError(&error) ?? false
        print(
            "compile \(name)/\(label): \(compiled)"
            + (compiled ? "" : " \(String(describing: error))")
        )
    }
}

print("\n== 4. did compiling launch anything? ==")
for (name, bundleID) in players {
    print("\(name) running after compile: \(isRunning(bundleID))")
}
