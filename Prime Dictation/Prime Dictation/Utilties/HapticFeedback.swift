import UIKit
import CoreHaptics

enum Haptic {
    static var supports: Bool {
        CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }

    /// Call once at app start (e.g., in viewDidAppear or AppDelegate).
    static func prepare() {
        guard supports else { return }
        UIImpactFeedbackGenerator(style: .rigid).prepare()
        UINotificationFeedbackGenerator().prepare()
    }

    static func tap(intensity: CGFloat = 1.0) {
        guard supports else { return }
        let gen = UIImpactFeedbackGenerator(style: .rigid)
        gen.prepare() // just-in-time prep for reliability
        if #available(iOS 13.0, *) {
            gen.impactOccurred(intensity: max(0, min(intensity, 1)))
        } else {
            gen.impactOccurred()
        }
    }

    static func success() {
        guard supports else { return }
        let gen = UINotificationFeedbackGenerator()
        gen.prepare() // just-in-time
        gen.notificationOccurred(.success)
    }

    static func debugPing() {
        print("Haptic.supports =", supports)
        tap(intensity: 1.0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { success() }
    }
}
