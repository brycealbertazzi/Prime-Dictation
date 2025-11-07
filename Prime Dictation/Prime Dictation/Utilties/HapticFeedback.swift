import UIKit
import CoreHaptics

enum Haptic {
    // Keep ONE generator; don't recreate on every tap.
    private static let impact = UIImpactFeedbackGenerator(style: .rigid)
    private static let notify = UINotificationFeedbackGenerator()

    static var supports: Bool { CHHapticEngine.capabilitiesForHardware().supportsHaptics }

    /// Call in viewDidAppear (and also on button touchDown for that crisp feel).
    static func prepare() {
        guard supports else { return }
        impact.prepare()
        notify.prepare()
    }

    /// Call on Touch Up Inside
    static func tap(intensity: CGFloat = 1.0) {
        guard supports else { return }
        if #available(iOS 13.0, *) {
            impact.impactOccurred(intensity: max(0, min(1, intensity)))
        } else {
            impact.impactOccurred()
        }
    }

    static func success() {
        guard supports else { return }
        notify.notificationOccurred(.success)
    }
}
