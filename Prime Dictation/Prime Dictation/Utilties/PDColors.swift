import UIKit

// MARK: - Hex Convenience

extension UIColor {
    /// Create a UIColor from a hex integer, e.g. 0xBA4A00
    convenience init(hex: Int, alpha: CGFloat = 1.0) {
        let red   = CGFloat((hex >> 16) & 0xFF) / 255.0
        let green = CGFloat((hex >> 8)  & 0xFF) / 255.0
        let blue  = CGFloat( hex        & 0xFF) / 255.0

        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }
}

// MARK: - App Colors

struct PDColors {
    static let orange = UIColor(hex: 0xBA4A00)
    static let blue = UIColor(hex: 0x0A66C2)
    static let red = UIColor(hex: 0xB03A2E)
    static let purple = UIColor(hex: 0x8E44AD)

    static let badgePurple = UIColor(hex: 0xD2C1F7)
    static let badgePurpleBorder = UIColor(hex: 0xBBA7F4)
    static let badgeGold = UIColor(hex: 0xF6C745)
    static let badgeGoldBorder = UIColor(hex: 0xE8C24A)

    static let black = UIColor(hex: 0x2C2C2E) // Charcoal-ish
    static let gray = UIColor(hex: 0x7F8C8D)
}

