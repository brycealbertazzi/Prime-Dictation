import UIKit
import StoreKit

@IBDesignable
final class PlanCardView: UIControl {

    var product: StoreKitManager.ProductID! {
        didSet {
            productId = product.rawValue
        }
    }
    private(set) var productId: String!
    
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
        let selected = isSelected

        // Animate between states so it feels responsive & premium
        UIView.animate(withDuration: 0.18,
                       delay: 0,
                       usingSpringWithDamping: 0.9,
                       initialSpringVelocity: 0.2,
                       options: [.beginFromCurrentState, .allowUserInteraction],
                       animations: { [weak self] in
            guard let self = self else { return }
            let baseView = self

            if selected {
                // Stronger border
                baseView.layer.borderWidth = 3
                baseView.layer.borderColor = UIColor.tintColor.cgColor

                // Brighter background
                baseView.backgroundColor = .systemBackground

                // Soft shadow to lift the card
                baseView.layer.shadowColor = UIColor.black.withAlphaComponent(0.15).cgColor
                baseView.layer.shadowOpacity = 1
                baseView.layer.shadowOffset = CGSize(width: 0, height: 4)
                baseView.layer.shadowRadius = 10

                // Slight “picked” pop
                baseView.transform = CGAffineTransform(scaleX: 1.02, y: 1.02)
            } else {
                baseView.layer.borderWidth = 1
                baseView.layer.borderColor = UIColor.separator.cgColor

                baseView.backgroundColor = .secondarySystemBackground

                baseView.layer.shadowOpacity = 0
                baseView.layer.shadowRadius = 0
                baseView.layer.shadowOffset = .zero

                baseView.transform = .identity
            }

            // If you have labels, you can also tweak their colors here, e.g.:
            // self.titleLabel.textColor = selected ? UIColor.label : UIColor.secondaryLabel
        }, completion: nil)
    }

}
