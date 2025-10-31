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

    override var isHighlighted: Bool {
        didSet { updateHighlightState() }
    }

    override var isEnabled: Bool {
        didSet { updateEnabledState() }
    }

    // if you want to make sure even IB-created buttons drop configs:
    override func awakeFromNib() {
        super.awakeFromNib()
        // always be a classic UIButton
        self.configuration = nil
        updateAppearance()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateAppearance()
    }

    // 👇 key part: make setTitle always win
    override func setTitle(_ title: String?, for state: UIControl.State) {
        // drop any config that might override titles
        self.configuration = nil
        super.setTitle(title, for: state)
        updateAppearance()
    }

    private func updateAppearance() {
        // outline
        layer.cornerRadius = cornerRadius
        layer.borderWidth = borderWidth
        layer.masksToBounds = true

        // border respects enabled
        if isEnabled {
            layer.borderColor = borderColor.cgColor
        } else {
            layer.borderColor = borderColor.withAlphaComponent(0.4).cgColor
        }

        // text colors
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

        // background
        if !isHighlighted {
            backgroundColor = .clear
        }

        // keep fully opaque
        titleLabel?.alpha = 1.0
        alpha = 1.0
    }

    private func updateHighlightState() {
        if isHighlighted {
            backgroundColor = borderColor.withAlphaComponent(0.2)
            titleLabel?.alpha = 1.0
            alpha = 1.0
        } else {
            backgroundColor = .clear
            titleLabel?.alpha = 1.0
            alpha = 1.0
        }
    }

    private func updateEnabledState() {
        updateAppearance()
    }
}
