import UIKit
import StoreKit

@IBDesignable
final class PlanCardView: UIControl {

    var product: StoreKitManager.ProductID! {
        didSet {
            productId = product.rawValue
            updateSelectionAppearance()   // ensure correct border on first layout
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
        baseView.layer.borderColor = UIColor.separator.cgColor
        baseView.backgroundColor = .secondarySystemBackground
    }

    private func setupTap() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        addGestureRecognizer(tap)
        isUserInteractionEnabled = true
    }

    @objc private func handleTap() {
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

        UIView.animate(withDuration: 0.18,
                       delay: 0,
                       usingSpringWithDamping: 0.9,
                       initialSpringVelocity: 0.2,
                       options: [.beginFromCurrentState, .allowUserInteraction],
                       animations: { [weak self] in
            guard let self = self else { return }
            let baseView = self

            if selected {
                // SELECTED STATE
                baseView.layer.borderWidth = 3

                baseView.layer.borderColor = UIColor.tintColor.cgColor

                baseView.backgroundColor = .systemBackground

                // Soft shadow to lift the card
                baseView.layer.shadowColor = UIColor.black.withAlphaComponent(0.15).cgColor
                baseView.layer.shadowOpacity = 1
                baseView.layer.shadowOffset = CGSize(width: 0, height: 4)
                baseView.layer.shadowRadius = 10

                // Slight “picked” pop
                baseView.transform = CGAffineTransform(scaleX: 1.02, y: 1.02)

            } else {
                // UNSELECTED STATE
                baseView.layer.borderWidth = 1

                if self.product == .lifetimeDeal {
                    baseView.layer.borderWidth = 2
                    baseView.layer.borderColor = PDColors.badgeGoldBorder.cgColor
                } else if self.product == .dailyAnnual {
                    baseView.layer.borderWidth = 2
                    baseView.layer.borderColor = PDColors.badgePurpleBorder.cgColor
                } else {
                    baseView.layer.borderColor = UIColor.separator.cgColor
                }

                baseView.backgroundColor = .secondarySystemBackground

                baseView.layer.shadowOpacity = 0
                baseView.layer.shadowRadius = 0
                baseView.layer.shadowOffset = .zero

                baseView.transform = .identity
            }
        }, completion: nil)
    }
}
