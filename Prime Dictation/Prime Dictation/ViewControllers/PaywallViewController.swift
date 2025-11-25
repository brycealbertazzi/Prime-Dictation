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

class PaywallViewController: UIViewController {
    
    @IBOutlet weak var BackButtonIcon: UIButton!
    @IBOutlet weak var ScrollView: UIScrollView!
    @IBOutlet weak var StackView: UIStackView!
    @IBOutlet weak var ContinueButton: RoundedButton!
    
    @IBOutlet weak var LTDView: PlanCardView!
    @IBOutlet weak var AnnualView: PlanCardView!
    @IBOutlet weak var StandardView: PlanCardView!
    @IBOutlet weak var MonthlyView: PlanCardView!
    
    @IBOutlet weak var ltdContainerView: UIView!      // outer wrapper for LTD card + badge
    @IBOutlet weak var ltdBadgeLabel: BadgeLabel!
    @IBOutlet weak var annualContainerView: UIView!   // outer wrapper for Annual card + badge
    @IBOutlet weak var annualBadgeLabel: BadgeLabel!
    
    // MARK: - Model

    enum Plan: String {
        case dailyAnnual
        case standard
        case dailyMonthly
        case lifetime
    }
    
    private var allCards: [PlanCardView] { [LTDView, AnnualView, StandardView, MonthlyView] }
    private(set) var selectedProduct: StoreKitManager.ProductID?

    private var cardToPlan: [PlanCardView: Plan] = [:]
    private var selectedPlan: Plan? {
        didSet { updateContinueButtonState() }
    }

    private weak var selectedCard: PlanCardView? {
        didSet {
            oldValue?.isSelected = false
            selectedCard?.isSelected = true
        }
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .light
        
        // Just to be explicit
        StackView.translatesAutoresizingMaskIntoConstraints = false

        // Make the content width match the scroll view’s visible width
        NSLayoutConstraint.activate([
            ScrollView.contentLayoutGuide.widthAnchor.constraint(
                equalTo: ScrollView.frameLayoutGuide.widthAnchor
            )
        ])

        configureCards()
        updateContinueButtonState()
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

    @objc private func cardTapped(_ sender: PlanCardView) {
        // 1) Update which card is selected
        selectedCard = sender
        selectedPlan = cardToPlan[sender]
        
        // 2) Make sure we have a plan
        guard let plan = selectedPlan else { return }
        
        // 3) Pick a button title based on the plan
        let buttonTitle: String
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
        
        // 4) Apply it to the button
        ContinueButton.setTitle(buttonTitle, for: .normal)
        
        // Optional: haptic
        Haptic.tap(intensity: 0.7)
    }

    @IBAction private func continueButtonTapped(_ sender: UIButton) {
        guard let plan = selectedPlan else {
            // Optional: shake / highlight cards
            return
        }

        // Handle purchase based on selected plan
        switch plan {
        case .dailyAnnual:
            startPurchase(for: AnnualView.productId)
        case .standard:
            startPurchase(for: StandardView.productId)
        case .dailyMonthly:
            startPurchase(for: MonthlyView.productId)
        case .lifetime:
            startPurchase(for: LTDView.productId)
        }
    }

    // MARK: - Helpers

    private func updateContinueButtonState() {
        let enabled = (selectedPlan != nil)
        ContinueButton.isEnabled = enabled
        ContinueButton.alpha = enabled ? 1.0 : 0.6
    }

    private func startPurchase(for productId: String) {
        // Hook up StoreKit flow here
        print("Selected productId: \(productId)")
    }
    
    @IBAction func BackButtonPressed(_ sender: Any) {
        Haptic.tap(intensity: 0.7)
        dismiss(animated: true)
    }
}
