import UIKit

@IBDesignable
class RoundedButton: UIButton {

    // MARK: - Inspectables

    @IBInspectable var cornerRadius: CGFloat = 8 {
        didSet { updateAppearance() }
    }

    @IBInspectable var borderWidth: CGFloat = 1 {
        didSet { updateAppearance() }
    }

    /// Main accent color for border + text when enabled
    @IBInspectable var color: UIColor = .systemBlue {
        didSet { updateAppearance() }
    }

    /// When true, button uses a filled style (solid background) when enabled.
    /// When false, it uses the outline / transparent style.
    @IBInspectable var filledStyle: Bool = false {
        didSet { updateAppearance() }
    }

    // MARK: - State

    override var isHighlighted: Bool {
        didSet { updateHighlightState() }
    }

    override var isEnabled: Bool {
        didSet { updateAppearance() }
    }

    // MARK: - Lifecycle

    override func awakeFromNib() {
        super.awakeFromNib()
        // Always behave like a classic UIButton (no UIButton.Configuration)
        configuration = nil
        setAttributedTitle(nil, for: .normal)
        updateAppearance()
    }

    override func layoutSubviews() {
        // Prevent configs from being reapplied
        configuration = nil
        super.layoutSubviews()
        updateAppearance()
    }

    // Ensure title updates cleanly
    override func setTitle(_ title: String?, for state: UIControl.State) {
        configuration = nil
        setAttributedTitle(nil, for: state)
        super.setTitle(title, for: state)
        titleLabel?.text = title
        setNeedsLayout()
        layoutIfNeeded()
    }

    // MARK: - Appearance helpers

    /// Sets title colors for all control states based on whether the
    /// visual style is filled or outline.
    private func setButtonTextColor(filled: Bool) {
        let normalColor: UIColor = filled ? .white : color

        setTitleColor(normalColor, for: .normal)
        setTitleColor(normalColor, for: .highlighted)
        setTitleColor(normalColor, for: .selected)

        // Slightly faded text for disabled
        let disabledColor = normalColor.withAlphaComponent(0.4)
        setTitleColor(disabledColor, for: .disabled)
    }

    private func updateAppearance() {
        layer.cornerRadius = cornerRadius
        layer.borderWidth = borderWidth
        layer.masksToBounds = true

        let accent = color

        if isEnabled {
            // Enabled border
            layer.borderColor = accent.cgColor

            if filledStyle {
                // Filled style when enabled
                backgroundColor = accent
                setButtonTextColor(filled: true)
            } else {
                // Outline style when enabled
                backgroundColor = .clear
                setButtonTextColor(filled: false)
            }
        } else {
            layer.borderColor = accent.withAlphaComponent(0.3).cgColor
            titleLabel?.alpha = 0.6
            if filledStyle {
                backgroundColor = accent.withAlphaComponent(0.3)
            }
        }

        alpha = 1.0
    }

    private func updateHighlightState() {
        // Simple pressed effect; works for both styles
        if isHighlighted {
            alpha = 0.8
        } else {
            alpha = 1.0
        }
    }
}
