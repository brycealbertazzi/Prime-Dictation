import UIKit

@IBDesignable
final class BadgeLabel: UILabel {

    // MARK: - Inspectables

    /// Extra horizontal padding around the text
    @IBInspectable var horizontalPadding: CGFloat = 10 {
        didSet { invalidateIntrinsicContentSize() }
    }

    /// Extra vertical padding around the text
    @IBInspectable var verticalPadding: CGFloat = 4 {
        didSet { invalidateIntrinsicContentSize() }
    }

    /// If true, corner radius will always be half the height (perfect pill)
    @IBInspectable var pillMode: Bool = true {
        didSet { setNeedsLayout() }
    }

    /// Fallback corner radius if pillMode is false
    @IBInspectable var cornerRadius: CGFloat = 12 {
        didSet { layer.cornerRadius = cornerRadius }
    }

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        clipsToBounds = true
        textAlignment = .center
        numberOfLines = 1
    }

    // MARK: - Layout & Padding

    override func layoutSubviews() {
        super.layoutSubviews()

        if pillMode {
            layer.cornerRadius = bounds.height / 2
        } else {
            layer.cornerRadius = cornerRadius
        }
    }

    override func drawText(in rect: CGRect) {
        let insets = UIEdgeInsets(
            top: verticalPadding,
            left: horizontalPadding,
            bottom: verticalPadding,
            right: horizontalPadding
        )
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: size.width + horizontalPadding * 2,
            height: size.height + verticalPadding * 2
        )
    }
}
