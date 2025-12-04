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
        didSet { updateAppearance() }
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

        let baseAccent = color

        // Accent color adjusted for state
        let accent: UIColor
        if !isEnabled {
            accent = baseAccent.withAlphaComponent(0.5)
        } else if isHighlighted {
            accent = baseAccent.withAlphaComponent(0.5)  // tweak this if you want
        } else {
            accent = baseAccent
        }

        layer.borderColor = accent.cgColor

        if isEnabled {
            if filledStyle {
                // Filled style
                backgroundColor = accent
                setButtonTextColor(filled: true)
            } else {
                // Outline style
                backgroundColor = .clear
                setButtonTextColor(filled: false)
            }
            titleLabel?.alpha = isHighlighted ? 0.5 : 1.0
            alpha = 1.0   // no whole-view alpha tricks needed anymore
        } else {
            // Disabled
            if filledStyle {
                backgroundColor = accent
                setButtonTextColor(filled: true)
            } else {
                backgroundColor = .clear
                setButtonTextColor(filled: false)
            }
            titleLabel?.alpha = 0.5
            alpha = 1.0
        }
    }

}
