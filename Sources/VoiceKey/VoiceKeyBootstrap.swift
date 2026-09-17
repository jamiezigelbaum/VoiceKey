import Foundation

/// Everything that must happen before the app delegate exists.
///
/// The delegate reads profiles during its own init, so a one-shot data
/// migration has nowhere later to go. Keeping that call here rather than inline
/// in `main.swift` means it can be tested: the clear runs once per install and
/// never gets a second chance, so a refactor of the entry point silently
/// dropping it would leave every upgraded user with the retired instructions
/// forever — the exact failure the owner already reported once.
enum VoiceKeyBootstrap {
    static func run(defaults: UserDefaults = .standard) {
        VoiceProfileStore.clearRetiredDefaultInstructions(defaults: defaults)
    }
}
