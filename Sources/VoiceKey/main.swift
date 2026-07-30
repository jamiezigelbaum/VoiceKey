import AppKit

// Runs before the delegate exists: the delegate reads profiles during its own
// init, so the one-shot clear has nowhere later to go.
VoiceProfileStore.clearRetiredDefaultInstructions()

let application = NSApplication.shared
let delegate = VoiceKeyAppDelegate()

application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
