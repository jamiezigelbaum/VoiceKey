import XCTest

/// Spins the run loop until `condition` holds, and fails the test if it never
/// does.
///
/// The onboarding wizard schedules work onto the next main-queue turn, which is
/// not a fixed duration. A fixed-duration `RunLoop.run(until:)` stands in for
/// that turn only while the machine is idle — on a loaded CI runner it starves,
/// and whatever asserts next fires against a state that simply hasn't happened
/// yet. On 2026-07-27 that took the entire suite down rather than one test: the
/// starved wait was followed by `removeFirst()` on an empty collection, which
/// traps the process. Wait on the observable condition instead of on a clock.
func waitUntil(
    _ condition: () -> Bool,
    timeout: TimeInterval = 2,
    _ message: @autoclosure () -> String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    let deadline = Date().addingTimeInterval(timeout)
    while condition() == false, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.005))
    }
    XCTAssertTrue(condition(), message(), file: file, line: line)
}
