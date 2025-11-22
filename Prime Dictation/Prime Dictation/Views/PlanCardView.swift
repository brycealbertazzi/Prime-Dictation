import UIKit

@IBDesignable
final class PlanCardView: UIControl {

    // MARK: - Init / Layout

    override func awakeFromNib() {
        super.awakeFromNib()
        setupView()
        setupTap()
    }

    override func prepareForInterfaceBuilder() {
        super.prepareForInterfaceBuilder()
        setupView()
    }

    private func setupView() {
        let baseView = self

        baseView.layer.cornerRadius = 16
        baseView.layer.masksToBounds = true
        baseView.layer.borderWidth = 1

        // Neutral default; will be overridden in updateSelectionAppearance()
        baseView.layer.borderColor = UIColor.separator.cgColor
        baseView.backgroundColor = UIColor.secondarySystemBackground

        updateSelectionAppearance()
    }

    private func setupTap() {
        // Because this is a UIControl, we can just use touchUpInside,
        // but a tap recognizer helps when embedded in stack views.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)
        isUserInteractionEnabled = true
    }

    @objc private func handleTap() {
        // Toggle selected state; your view controller can enforce single-selection
        isSelected = true
        sendActions(for: .primaryActionTriggered)
    }

    // MARK: - Selection Styling

    override var isHighlighted: Bool {
        didSet {
            updateSelectionAppearance()
        }
    }

    override var isSelected: Bool {
        didSet {
            updateSelectionAppearance()
        }
    }

    private func updateSelectionAppearance() {
        let baseView = self
        let selected = isSelected

        // Border + background
        if selected {
            baseView.layer.borderColor = tintColor.cgColor
            baseView.backgroundColor = tintColor.withAlphaComponent(0.08)
        } else {
            baseView.layer.borderColor = UIColor.separator.cgColor
            baseView.backgroundColor = UIColor.secondarySystemBackground
        }

        // Subtle press effect
        if isHighlighted {
            baseView.alpha = 0.8
        } else {
            baseView.alpha = 1.0
        }
    }
}
