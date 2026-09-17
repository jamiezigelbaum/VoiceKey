import Foundation
import XCTest

/// Creation and destruction of the throwaway `UserDefaults` suites tests use.
///
/// Destroying one takes two steps, and missing either leaks a file per test:
/// `removePersistentDomain(forName:)` empties the suite but leaves its backing
/// plist in `~/Library/Preferences` — a 42-byte husk that `defaults domains`
/// still lists. Measured on one Mac, 2026-07-28: 3107 stray files and 7.3 MB,
/// because every test that looked like it cleaned up left an empty plist, and
/// `SettingsAutoApplyTests` removed only its *keys*, so its files kept their
/// contents as well.
///
/// One residue cannot be removed from inside the test process, and pretending
/// otherwise would be the kind of claim this project does not make: at `atexit`
/// the directory is verifiably clean, and `cfprefsd` then writes empty husks
/// back *after* the process is gone, flushing domain state it held in memory
/// during the run. Measured across consecutive runs: sometimes none, sometimes
/// ~40 files totalling under 2 KB. So the sweep runs at both ends, and the one
/// on the way in is the load-bearing half — it means the count is bounded by a
/// single run rather than accumulating, and every run starts from zero.
enum TestDefaultsSuite {
    /// One prefix for every test suite in the package, so a stray one is
    /// greppable and the gate below can find it.
    static let prefix = "VoiceKeyTests."

    static func makeName() -> String {
        prefix + UUID().uuidString
    }

    /// Both halves of the cleanup, and both are needed: emptying the domain
    /// leaves the husk, deleting the file alone leaves the values live in
    /// `cfprefsd`. Safe to call twice.
    ///
    /// This is enough on its own *within* the run — at `atexit` the directory
    /// is empty — so anything found later was written back by `cfprefsd` after
    /// the process died, which is what `FinalSweep` exists for.
    static func destroy(_ name: String, defaults: UserDefaults) {
        defaults.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: plistURL(for: name))
    }

    /// Deletes every suite plist still standing, on the first suite of a run
    /// and again at process exit.
    ///
    /// The sweep on the way in is the load-bearing one: it removes what
    /// `cfprefsd` wrote back after the *previous* run exited, so a run always
    /// starts from an empty field and the residue stays bounded instead of
    /// accumulating forever.
    enum FinalSweep {
        private static var isRegistered = false

        static func register() {
            guard isRegistered == false else { return }
            isRegistered = true
            sweep()
            atexit { TestDefaultsSuite.FinalSweep.sweep() }
        }

        static func sweep() {
            for name in TestDefaultsSuite.strayNames() {
                try? FileManager.default.removeItem(
                    at: TestDefaultsSuite.plistURL(for: name)
                )
            }
        }
    }

    static func plistURL(for name: String) -> URL {
        preferencesDirectory.appendingPathComponent("\(name).plist")
    }

    /// Suite plists left in `~/Library/Preferences` by any earlier test.
    static func strayNames() -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            atPath: preferencesDirectory.path
        )) ?? []
        return contents
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".plist") }
            .map { String($0.dropLast(".plist".count)) }
    }

    private static var preferencesDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Preferences")
    }
}

extension XCTestCase {
    /// A throwaway `UserDefaults` suite that cannot outlive the test that made
    /// it: the teardown is registered at creation, so there is no way to obtain
    /// one of these and forget to clean it up.
    ///
    /// This is the only sanctioned way to build a suite in this package —
    /// `testNoTestBuildsAUserDefaultsSuiteByHand` fails the build's own suite if
    /// another test constructs `UserDefaults(suiteName:)` directly.
    func makeTestDefaults() -> UserDefaults {
        makeTestDefaultsSuite().defaults
    }

    /// The same suite, with its name — for the few tests that need to name the
    /// domain, and for the gate that proves the teardown really fires.
    ///
    /// Deliberately not `throws`: several call sites are helpers that are not
    /// themselves throwing, and a fresh UUID under a fixed prefix is always a
    /// valid suite name. If this ever fails, the environment is broken rather
    /// than the test.
    func makeTestDefaultsSuite() -> (name: String, defaults: UserDefaults) {
        TestDefaultsSuite.FinalSweep.register()
        let name = TestDefaultsSuite.makeName()
        guard let defaults = UserDefaults(suiteName: name) else {
            preconditionFailure(
                "could not open the throwaway suite \(name)"
            )
        }
        // A previous run that died mid-test could have left values behind under
        // a colliding name; start from empty regardless.
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock {
            TestDefaultsSuite.destroy(name, defaults: defaults)
        }
        return (name, defaults)
    }
}
