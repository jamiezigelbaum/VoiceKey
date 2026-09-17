import Foundation

final class MenuBarIconAnimator {
    var onFrame: ((Double) -> Void)?

    private(set) var phase: Double = 0

    private var timer: Timer?

    deinit {
        timer?.invalidate()
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            self?.advanceForTesting()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func advanceForTesting() {
        phase += 1.0 / 12.0
        if phase >= 1.0 {
            phase -= 1.0
        }
        onFrame?(phase)
    }
}
