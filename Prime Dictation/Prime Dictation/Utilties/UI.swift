import UIKit

@IBDesignable
class RoundedButton: UIButton {

    @IBInspectable var cornerRadius: CGFloat = 8 {
        didSet { updateAppearance() }
    }

    @IBInspectable var borderWidth: CGFloat = 1 {
        didSet { updateAppearance() }
    }

    @IBInspectable var borderColor: UIColor = .systemBlue {
        didSet { updateAppearance() }
    }

    // padding
    @IBInspectable var paddingTop: CGFloat = 6 {
        didSet { updateAppearance() }
    }
    @IBInspectable var paddingLeft: CGFloat = 12 {
        didSet { updateAppearance() }
    }
    @IBInspectable var paddingBottom: CGFloat = 6 {
        didSet { updateAppearance() }
    }
    @IBInspectable var paddingRight: CGFloat = 12 {
        didSet { updateAppearance() }
    }

    // highlight
    override var isHighlighted: Bool {
        didSet {
            updateHighlightState()
        }
    }

    override func awakeFromNib() {
        super.awakeFromNib()

        // make sure no config is interfering
        if #available(iOS 15.0, *) {
            self.configuration = nil
        }

        updateAppearance()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateAppearance()
    }

    private func updateAppearance() {
        // outline
        layer.cornerRadius = cornerRadius
        layer.borderWidth = borderWidth
        layer.borderColor = borderColor.cgColor
        layer.masksToBounds = true

        // text colors – lock them
        setTitleColor(borderColor, for: .normal)
        setTitleColor(borderColor, for: .highlighted)
        setTitleColor(borderColor, for: .selected)
        setTitleColor(borderColor.withAlphaComponent(0.4), for: .disabled)

        // padding
        contentEdgeInsets = UIEdgeInsets(
            top: paddingTop,
            left: paddingLeft,
            bottom: paddingBottom,
            right: paddingRight
        )

        // background when not pressed
        if !isHighlighted {
            backgroundColor = .clear
        }

        // 🔒 make sure title is fully visible
        titleLabel?.alpha = 1.0
        alpha = 1.0
    }

    private func updateHighlightState() {
        if isHighlighted {
            // show pressed bg
            backgroundColor = borderColor.withAlphaComponent(0.12)

            // 🔒 UIKit likes to dim the label here — undo it
            titleLabel?.alpha = 1.0
            alpha = 1.0
        } else {
            backgroundColor = .clear
            titleLabel?.alpha = 1.0
            alpha = 1.0
        }
    }
}
