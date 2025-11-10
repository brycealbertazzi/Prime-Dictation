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
    
    @IBInspectable var textColor: UIColor = .systemBlue {
        didSet { updateAppearance() }
    }

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

    override func awakeFromNib() {
        super.awakeFromNib()
        // always behave like an old-school UIButton
        self.configuration = nil
        // also clear any attributed title IB may have snuck in
        super.setAttributedTitle(nil, for: .normal)
        updateAppearance()
    }

    override func layoutSubviews() {
        // kill config every layout so IB / system can’t reapply it
        self.configuration = nil
        super.layoutSubviews()
        updateAppearance()
    }

    // 👇 this is the important part
    override func setTitle(_ title: String?, for state: UIControl.State) {
        // 1) no configs
        self.configuration = nil
        // 2) no attributed title
        super.setAttributedTitle(nil, for: state)
        // 3) normal UIButton behavior
        super.setTitle(title, for: state)
        // 4) force the actual label to match (bypasses UIButton cleverness)
        self.titleLabel?.text = title
        // 5) relayout
        setNeedsLayout()
        layoutIfNeeded()
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
        setTitleColor(textColor, for: .normal)
        setTitleColor(textColor, for: .highlighted)
        setTitleColor(textColor, for: .selected)
        setTitleColor(textColor.withAlphaComponent(0.4), for: .disabled)

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

        titleLabel?.alpha = 1.0
        alpha = 1.0
    }

    private func updateHighlightState() {
        if isHighlighted {
            backgroundColor = textColor.withAlphaComponent(0.2)
            titleLabel?.alpha = 1.0
        } else {
            backgroundColor = .clear
            titleLabel?.alpha = 1.0
        }
    }

    private func updateEnabledState() {
        updateAppearance()
    }
}
