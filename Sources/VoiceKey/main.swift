import AppKit

// Runs before the delegate exists: the delegate reads profiles during its own
// init, so the one-shot clear has nowhere later to go. The work lives in
// VoiceKeyBootstrap so it is reachable from tests; this line is the only part
// that cannot be.
VoiceKeyBootstrap.run()

let application = NSApplication.shared
let delegate = VoiceKeyAppDelegate()

application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
