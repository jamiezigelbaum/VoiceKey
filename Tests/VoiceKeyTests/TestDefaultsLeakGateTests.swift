import Foundation
import XCTest

/// The gate for a leak that ran unnoticed for the life of the project: every
/// test that made a `UserDefaults` suite left a plist behind in
/// `~/Library/Preferences`, 3107 of them on one Mac by 2026-07-28. A prose rule
/// would have been forgotten the same way the cleanup was, so the leak is
/// checked here instead.
final class TestDefaultsLeakGateTests: XCTestCase {
    /// A real test case whose only job is to make a suite the sanctioned way
    /// and finish, so the gate can look at what it left behind.
    private final class SuiteMakingProbe: XCTestCase {
        /// Set by the probe's own test method, read after it has fully run.
        static var madeSuiteName: String?

        func testMakesASuiteAndWritesToIt() throws {
            let suite = makeTestDefaultsSuite()
            SuiteMakingProbe.madeSuiteName = suite.name
            // Force the backing plist into existence: an untouched suite may
            // never be written at all, which would make this gate vacuous.
            suite.defaults.set("value", forKey: "key")
            suite.defaults.synchronize()
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: TestDefaultsSuite.plistURL(for: suite.name).path
                ),
                "the probe's suite was never written, so the gate would prove nothing"
            )
        }
    }

    func testASuiteMadeByTheHelperDoesNotOutliveItsTest() throws {
        SuiteMakingProbe.madeSuiteName = nil

        let probe = SuiteMakingProbe(
            selector: #selector(SuiteMakingProbe.testMakesASuiteAndWritesToIt)
        )
        probe.run()

        XCTAssertEqual(
            probe.testRun?.failureCount,
            0,
            "the probe itself failed, so this gate cannot say anything"
        )

        let name = try XCTUnwrap(
            SuiteMakingProbe.madeSuiteName,
            "the probe never made a suite"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: TestDefaultsSuite.plistURL(for: name).path
            ),
            """
            \(name).plist outlived the test that made it. \
            removePersistentDomain(forName:) empties a suite but leaves the \
            file; TestDefaultsSuite.destroy must remove both.
            """
        )
    }

    /// The structural half: a suite built by hand skips the teardown entirely,
    /// so no test may build one.
    func testNoTestBuildsAUserDefaultsSuiteByHand() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        let sanctioned = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("TestDefaultsSuite.swift")
            .lastPathComponent

        let files = try FileManager.default.contentsOfDirectory(
            atPath: testsDirectory.path
        )
        .filter { $0.hasSuffix(".swift") && $0 != sanctioned }

        XCTAssertFalse(
            files.isEmpty,
            "found no test sources to scan — the gate would be vacuous"
        )

        // Assembled from pieces so this file does not match its own search and
        // report itself as an offender.
        let handBuiltSuite = "UserDefaults(" + "suiteName"

        var offenders: [String] = []
        for file in files {
            let source = try String(
                contentsOf: testsDirectory.appendingPathComponent(file),
                encoding: .utf8
            )
            if source.contains(handBuiltSuite) {
                offenders.append(file)
            }
        }

        XCTAssertEqual(
            offenders.sorted(),
            [],
            """
            these tests build a UserDefaults suite by hand and so skip the \
            automatic teardown — use makeTestDefaults() instead
            """
        )
    }
}
