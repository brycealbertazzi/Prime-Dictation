//
//  PaywallViewController.swift
//  Prime Dictation
//
//  Created by Bryce Albertazzi on 11/21/25.
//  Copyright © 2025 Bryce Albertazzi. All rights reserved.
//

import UIKit
import AVFoundation
import ProgressHUD
import StoreKit

class PaywallViewController: UIViewController {
    
    @IBOutlet weak var BackButtonIcon: UIButton!
    @IBOutlet weak var ScrollView: UIScrollView!
    @IBOutlet weak var StackView: UIStackView!
    @IBOutlet weak var ContinueButton: RoundedButton!
    @IBOutlet weak var RestorePurchasesButton: UIButton!
    
    @IBOutlet weak var LTDView: PlanCardView!
    @IBOutlet weak var AnnualView: PlanCardView!
    @IBOutlet weak var StandardView: PlanCardView!
    @IBOutlet weak var MonthlyView: PlanCardView!
    
    @IBOutlet weak var ltdContainerView: UIView!      // outer wrapper for LTD card + badge
    @IBOutlet weak var ltdBadgeLabel: BadgeLabel!
    @IBOutlet weak var annualContainerView: UIView!   // outer wrapper for Annual card + badge
    @IBOutlet weak var annualBadgeLabel: BadgeLabel!
    
    private let subscriptionManager = AppServices.shared.subscriptionManager

    // MARK: - Model

    enum Plan: String {
        case dailyAnnual
        case standard
        case dailyMonthly
        case lifetime
    }
    
    private var allCards: [PlanCardView] { [LTDView, AnnualView, StandardView, MonthlyView] }

    private var cardToPlan: [PlanCardView: Plan] = [:]
    private var selectedPlan: Plan?
    private weak var selectedCard: PlanCardView? {
        didSet {
            oldValue?.isSelected = false
            selectedCard?.isSelected = true
        }
    }
    
    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .darkContent
    }

    // MARK: - Lifecycle

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        setNeedsStatusBarAppearanceUpdate()
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .light
        
        StackView.translatesAutoresizingMaskIntoConstraints = false

        // Make the content width match the scroll view’s visible width
        NSLayoutConstraint.activate([
            ScrollView.contentLayoutGuide.widthAnchor.constraint(
                equalTo: ScrollView.frameLayoutGuide.widthAnchor
            )
        ])
        ScrollView.delaysContentTouches = false
        
        configureCards()
        preselectPlan()
        
        let title = "Restore Purchases"

        let normal = NSAttributedString(
            string: title,
            attributes: [
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: PDColors.black,
                .font: UIFont.systemFont(ofSize: 14, weight: .semibold)
            ]
        )

        let highlighted = NSAttributedString(
            string: title,
            attributes: [
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: PDColors.black.withAlphaComponent(0.6),
                .font: UIFont.systemFont(ofSize: 14, weight: .semibold)
            ]
        )

        RestorePurchasesButton.setAttributedTitle(normal, for: .normal)
        RestorePurchasesButton.setAttributedTitle(highlighted, for: .highlighted)
    }
    
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        // Make sure badges are always above their cards
        ltdContainerView.bringSubviewToFront(ltdBadgeLabel)
        annualContainerView.bringSubviewToFront(annualBadgeLabel)
    }

    // MARK: - Setup

    private func configureCards() {
        // 1) Attach StoreKit products
        LTDView.product      = .lifetimeDeal
        AnnualView.product   = .dailyAnnual
        StandardView.product = .standardMonthly
        MonthlyView.product  = .dailyMonthly

        // 2) Map views -> Plan enum so we can look them up on tap
        cardToPlan = [
            LTDView:      .lifetime,
            AnnualView:   .dailyAnnual,
            StandardView: .standard,
            MonthlyView:  .dailyMonthly
        ]

        // 3) Register tap handler for all cards
        allCards.forEach { card in
            card.addTarget(self, action: #selector(cardTapped(_:)), for: .primaryActionTriggered)
        }
    }
    
    // MARK: - Actions
    
    private func preselectPlan() {
        let manager = StoreKitManager.shared
        let current = manager.currentPlan   // we’ll define this in a sec
        
        let cardToSelect: PlanCardView?

        switch current {
        case .some(.dailyAnnual):
            cardToSelect = AnnualView
        case .some(.standardMonthly):
            cardToSelect = StandardView
        case .some(.dailyMonthly):
            cardToSelect = MonthlyView
        case .some(.lifetimeDeal):
            cardToSelect = LTDView
        case .none:
            // No sub – push them toward annual by default
            cardToSelect = AnnualView
        }

        if let card = cardToSelect {
            cardTapped(card)   // reuses your existing logic
        }
    }

    private var currentProduct: StoreKitManager.ProductID? {
        StoreKitManager.shared.currentPlan
    }

    @objc private func cardTapped(_ sender: PlanCardView) {
        selectedCard = sender
        selectedPlan = cardToPlan[sender]

        guard let plan = selectedPlan else { return }

        // Map Plan -> product ID used by StoreKitManager
        let productId: StoreKitManager.ProductID
        switch plan {
        case .dailyAnnual:
            productId = .dailyAnnual
        case .standard:
            productId = .standardMonthly
        case .dailyMonthly:
            productId = .dailyMonthly
        case .lifetime:
            productId = .lifetimeDeal
        }

        let isCurrent = (productId == currentProduct)

        let buttonTitle: String
        if isCurrent {
            buttonTitle = "Current Plan"
        } else {
            // Normal purchase titles
            switch plan {
            case .dailyAnnual:
                buttonTitle = "Continue - $99.99"
            case .standard:
                buttonTitle = "Continue - $4.99"
            case .dailyMonthly:
                buttonTitle = "Continue - $19.99"
            case .lifetime:
                buttonTitle = "Continue - $79.99"
            }
        }

        setBadgeColors(plan: plan)
        ContinueButton.setTitle(buttonTitle, for: .normal)

        Haptic.tap(intensity: 0.7)
    }

    @IBAction private func continueButtonTapped(_ sender: UIButton) {
        guard let card = selectedCard else {
            return
        }
        
        guard let selectedProduct = card.product else {
            return
        }
        
        if currentProduct == selectedProduct {
            let alert = UIAlertController(
                title: "Already Subscribed",
                message: "You’re already on this plan. If you recently changed plans, the new plan may not start until your next billing date. You can manage your subscription in the App Store.",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        
        Task {
            await startPurchase(for: selectedProduct)
        }
    }

    // MARK: - Helpers

    private func setBadgeColors(plan: Plan) {
        if plan == .dailyAnnual {
            annualBadgeLabel.backgroundColor = .systemBlue
            annualBadgeLabel.textColor = UIColor.systemBackground
            ltdBadgeLabel.backgroundColor = PDColors.badgeGoldBorder
            ltdBadgeLabel.textColor = UIColor.black
        } else if plan == .lifetime {
            ltdBadgeLabel.backgroundColor = .systemBlue
            ltdBadgeLabel.textColor = UIColor.systemBackground
            annualBadgeLabel.backgroundColor = PDColors.badgePurpleBorder
            annualBadgeLabel.textColor = UIColor.black
        } else {
            annualBadgeLabel.backgroundColor = PDColors.badgePurpleBorder
            annualBadgeLabel.textColor = UIColor.black
            ltdBadgeLabel.backgroundColor = PDColors.badgeGoldBorder
            ltdBadgeLabel.textColor = UIColor.black
        }
    }
    
    private func startPurchase(for productId: StoreKitManager.ProductID) async {
        do {
            let manager = StoreKitManager.shared
            try await manager.purchase(productId)
            manager.applyEntitlements(to: subscriptionManager)

            subscriptionManager.trialManager.usage = TrialUsage(
                totalSeconds: TrialManager.TRIAL_LIMIT,
                state: .completed
            )
            
            if (productId == .lifetimeDeal) {
                openSubscriptionsAlert(
                    title: "Subscriptions Notice",
                    message: "If you had an active subscription, make sure to cancel it so you will not be billed again.",
                    handler: {self.openManageSubscriptions(dismissOnReturn: true)}
                )
            } else {
                dismiss(animated: true)
            }
        } catch let error as StoreKitManager.PurchaseError {
            switch error {
            case .userCancelled:
                // 👇 This is the “cancelled from the sheet” case
                displayAlert(
                    title: "Purchase Cancelled",
                    message: currentProduct != nil ? "No changes were made to your subscription." : "The subscription selection sheet was dismissed without making a purchase."
                )
            case .pending:
                displayAlert(
                    title: "Purchase Pending",
                    message: "Your purchase is pending approval. Please try again later."
                )
            default:
                displayAlert(
                    title: "Purchase Cancelled",
                    message: currentProduct != nil ? "No changes were made to your subscription." : "The subscription selection sheet was dismissed without making a purchase."
                )
            }
        } catch {
            print("Unable to purchase product: \(error)")
            displayAlert(
                title: "Purchase Cancelled",
                message: currentProduct != nil ? "No changes were made to your subscription." : "The subscription selection sheet was dismissed without making a purchase."
            )
        }
    }


    
    @IBAction func BackButtonPressed(_ sender: Any) {
        Haptic.tap(intensity: 0.7)
        dismiss(animated: true)
    }
    
    @IBAction func RestorePurchasesButtonPressed(_ sender: Any) {
        Haptic.tap(intensity: 0.7)

        Task {
            ProgressHUD.animate("Restoring purchases...", .triangleDotShift)

            let manager = StoreKitManager.shared
            await manager.refreshEntitlements()
            manager.applyEntitlements(to: subscriptionManager)

            ProgressHUD.dismiss()

            if subscriptionManager.isSubscribed {
                subscriptionManager.trialManager.usage = TrialUsage(
                    totalSeconds: TrialManager.TRIAL_LIMIT,
                    state: .completed
                )

                displayAlert(
                    title: "Purchases Restored",
                    message: "Your previous purchases have been restored.",
                    handler: { self.dismiss(animated: true) }
                )
            } else {
                displayAlert(
                    title: "No Purchases Found",
                    message: "We couldn’t find any previous purchases for this Apple ID."
                )
            }
        }
    }
    
    func displayAlert(title: String, message: String, handler: (@MainActor () -> Void)? = nil) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: {_ in
            handler?()
        }))
        present(alert, animated: true, completion: nil)
    }
    
    func openSubscriptionsAlert(title: String, message: String, handler: (@MainActor () -> Void)? = nil) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel, handler: {_ in
            self.dismiss(animated: true)
        }))
        alert.addAction(UIAlertAction(title: "Subscriptions", style: .default, handler: {_ in
            handler?()
        }))
        present(alert, animated: true, completion: nil)
    }
    
    func openManageSubscriptions(dismissOnReturn: Bool = true) {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            return
        }

        Task { [weak self] in
            do {
                try await AppStore.showManageSubscriptions(
                    in: windowScene,
                    subscriptionGroupID: StoreKitManager.SubscriptionConfig.subscriptionGroupID
                )
            } catch {
                // Fallback to the web if native sheet fails
                if let url = URL(string: "https://apps.apple.com/account/subscriptions") {
                    await UIApplication.shared.open(url)
                }
            }

            // This runs AFTER the native manage-subscriptions sheet is closed
            if dismissOnReturn {
                await MainActor.run {
                    self?.dismiss(animated: true)
                }
            }
        }
    }
    
}
