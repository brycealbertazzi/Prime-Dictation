import UIKit
import AVFoundation
import ProgressHUD

class TranscriptionViewController: UIViewController {
    var recordingManager: RecordingManager!
    var transcriptText: String?
    
    @IBOutlet weak var TranscriptionTextBox: UITextView!
    
    // NEW: slider and two buttons
    @IBOutlet weak var fontSizeSlider: UISlider!
    @IBOutlet weak var chooseFontButton: UIButton!
    @IBOutlet weak var fontSizeButton: UIButton!
    
    private let userDefaultsFontSettingsKey = "transcriptionFontSettings"
    
    private struct FontSelection: Codable {
        let title: String
        let fontName: String?   // nil means "use system font"
    }
    
    private struct FontSettings: Codable {
        var choice: FontSelection
        var size: Double
    }
    
    private let lineHeightMultiple: CGFloat = 1.2   // tweak between 1.1–1.25 to taste

    // 12 font options
    private let fontChoices: [FontSelection] = [
        FontSelection(title: "PingFang MO",      fontName: "PingFangHK-Regular"),
        FontSelection(title: "System",           fontName: nil),
        FontSelection(title: "Avenir Next",      fontName: "AvenirNext-Regular"),
        FontSelection(title: "Helvetica Neue",   fontName: "HelveticaNeue"),
        FontSelection(title: "Georgia",          fontName: "Georgia"),
        FontSelection(title: "Times New Roman",  fontName: "TimesNewRomanPSMT"),
        FontSelection(title: "Courier New",      fontName: "CourierNewPSMT"),
        FontSelection(title: "Menlo",            fontName: "Menlo-Regular"),
        FontSelection(title: "Optima",           fontName: "Optima-Regular"),
        FontSelection(title: "Palatino",         fontName: "Palatino-Roman"),
        FontSelection(title: "Noteworthy",       fontName: "Noteworthy-Light"),
        FontSelection(title: "Chalkboard SE",    fontName: "ChalkboardSE-Regular")
    ]
    private var selectedFontChoice = FontSelection(title: "PingFang MO", fontName: "PingFangHK-Regular")
    static let DEFAULT_TEXT_SIZE: CGFloat = 20.0
    private var selectedFontSize: CGFloat = DEFAULT_TEXT_SIZE

    // Backing settings object for persistence
    private var fontSettings = FontSettings(
        choice: FontSelection(title: "PingFang MO", fontName: "PingFangHK-Regular"),
        size: DEFAULT_TEXT_SIZE
    )
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        let services = AppServices.shared
        recordingManager = services.recordingManager
        
        TranscriptionTextBox.text = transcriptText
        loadUserDefaultFontSettings()
        applyFontAndLineSpacing()
        
        // Option to press Done action item on keyboard toolbar to dismiss
        addDoneButtonToKeyboard()
        
        // Configure font slider (hidden by default)
        setupFontSizeSlider()
        
        // Listen for keyboard show/hide to adjust insets
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(keyboardWillShow(_:)),
                                               name: UIResponder.keyboardWillShowNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(keyboardWillHide(_:)),
                                               name: UIResponder.keyboardWillHideNotification,
                                               object: nil)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    func loadUserDefaultFontSettings() {
        if let saved = UserDefaults.standard.loadCodable(FontSettings.self,
                                                         forKey: userDefaultsFontSettingsKey) {
            fontSettings = saved
            selectedFontChoice = saved.choice
            selectedFontSize = CGFloat(saved.size)
            print("Loaded saved font choice: \(saved.choice.title), size: \(saved.size)")
        } else {
            // First launch / nothing saved yet
            fontSettings = FontSettings(
                choice: fontChoices[0],  // PingFang MO
                size: TranscriptionViewController.DEFAULT_TEXT_SIZE
            )
            selectedFontChoice = fontSettings.choice
            selectedFontSize = CGFloat(fontSettings.size)
            print("No saved font settings, using defaults: \(selectedFontChoice.title), \(TranscriptionViewController.DEFAULT_TEXT_SIZE)")
        }
    }
    
    private func applyFontAndLineSpacing() {
        guard let text = TranscriptionTextBox.text else { return }

        // Build the font from current selection + size
        let font: UIFont
        if let name = selectedFontChoice.fontName {
            font = makeSemibold(name, size: selectedFontSize)
        } else {
            font = makeSemibold(nil, size: selectedFontSize)
        }

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineHeightMultiple = lineHeightMultiple
        // Optional: small paragraph spacing
        // paragraphStyle.paragraphSpacing = font.pointSize * 0.2

        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraphStyle
        ]

        // Apply to existing text
        TranscriptionTextBox.attributedText = NSAttributedString(string: text, attributes: attrs)

        // Ensure newly typed text uses same style
        TranscriptionTextBox.typingAttributes = attrs
    }
    
    private func makeSemibold(_ fontName: String?, size: CGFloat) -> UIFont {
        // 1. If we have a specific font name
        if let name = fontName {
            // Special case: PingFang HK
            if name.contains("PingFangHK") {
                if let semi = UIFont(name: "PingFangHK-Semibold", size: size) {
                    return semi
                }
            }
            
            // Try a "-Semibold" variant
            if name.hasSuffix("-Regular") {
                let semiName = name.replacingOccurrences(of: "-Regular", with: "-Semibold")
                if let semi = UIFont(name: semiName, size: size) {
                    return semi
                }
                
                // Fallback: try "-Bold"
                let boldName = name.replacingOccurrences(of: "-Regular", with: "-Bold")
                if let bold = UIFont(name: boldName, size: size) {
                    return bold
                }
            }
            
            // Try bold traits on the base font
            if let baseFont = UIFont(name: name, size: size),
               let boldDescriptor = baseFont.fontDescriptor.withSymbolicTraits(.traitBold) {
                return UIFont(descriptor: boldDescriptor, size: size)
            }
        }
        
        // 2. No specific font or everything above failed → system semibold
        return UIFont.systemFont(ofSize: size, weight: .semibold)
    }

    
    private func persistFontSettings() {
        fontSettings.choice = selectedFontChoice
        fontSettings.size = Double(selectedFontSize)

        do {
            try UserDefaults.standard.setCodable(fontSettings, forKey: userDefaultsFontSettingsKey)
            print("Saved font settings: choice=\(fontSettings.choice.title), size=\(fontSettings.size)")
        } catch {
            print("Failed to save font settings")
        }

        // 🔐 Force a disk write (mainly useful while debugging)
        UserDefaults.standard.synchronize()
    }
    
    // MARK: - Font size slider
    
    private func setupFontSizeSlider() {
        // Reasonable range for transcript text
        fontSizeSlider.minimumValue = 10
        fontSizeSlider.maximumValue = 40
        
        let currentSize = Float(TranscriptionTextBox.font?.pointSize ?? 18)
        fontSizeSlider.value = currentSize
        
        if let font = TranscriptionTextBox.font {
            TranscriptionTextBox.font = font.withSize(CGFloat(fontSizeSlider.value))
        } else {
            TranscriptionTextBox.font = UIFont.systemFont(ofSize: CGFloat(fontSizeSlider.value))
        }
        
        // Start hidden
        fontSizeSlider.alpha = 0
        fontSizeSlider.isHidden = true
        
        // Wire events in code:
        fontSizeSlider.addTarget(self,
                                 action: #selector(fontSizeSliderChanged(_:)),
                                 for: .valueChanged)
        
        // Hide as soon as finger lifts or interaction is cancelled
        fontSizeSlider.addTarget(self,
                                 action: #selector(fontSizeSliderTouchEnded(_:)),
                                 for: [.touchUpInside, .touchUpOutside, .touchCancel])
    }
    
    private func showFontSizeSlider() {
        if fontSizeSlider.isHidden {
            fontSizeSlider.isHidden = false
            UIView.animate(withDuration: 0.2) {
                self.fontSizeSlider.alpha = 1.0
            }
        }
    }
    
    private func hideFontSizeSlider() {
        guard !fontSizeSlider.isHidden else { return }
        UIView.animate(withDuration: 0.2, animations: {
            self.fontSizeSlider.alpha = 0.0
        }, completion: { _ in
            self.fontSizeSlider.isHidden = true
        })
    }
    
    @objc private func fontSizeSliderChanged(_ sender: UISlider) {
        let newSize = CGFloat(sender.value)
        selectedFontSize = newSize

        UIView.animate(withDuration: 0.1) {
            self.applyFontAndLineSpacing()
        }
    }
    
    @objc private func fontSizeSliderTouchEnded(_ sender: UISlider) {
        let newSize = CGFloat(sender.value)
        selectedFontSize = newSize
        print("new font size: \(newSize)")
        
        // Persist settings
        persistFontSettings()
        hideFontSizeSlider()
    }
    
    // MARK: - Alerts
    
    func displayAlert(title: String, message: String, handler: (@MainActor () -> Void)? = nil) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: {_ in
            handler?()
        }))
        present(alert, animated: true, completion: nil)
    }
    
    // MARK: - Keyboard toolbar
    
    private func addDoneButtonToKeyboard() {
        let toolbar = UIToolbar()
        toolbar.sizeToFit()
        let flex = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)
        let done = UIBarButtonItem(title: "Done", style: .done, target: self, action: #selector(dismissKeyboard))
        toolbar.items = [flex, done]
        TranscriptionTextBox.inputAccessoryView = toolbar
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
        // Save the updated text to the recording manager
        guard let newText = TranscriptionTextBox.text else {
            ProgressHUD.failed("Failed to update transcription")
            return
        }
        recordingManager.UpdateToggledTranscriptionText(newText: newText, editing: true)
    }
    
    // MARK: - Keyboard handling
    
    @objc private func keyboardWillShow(_ notification: Notification) {
        guard
            let userInfo = notification.userInfo,
            let frameValue = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue
        else { return }
        
        let keyboardFrameInScreen = frameValue.cgRectValue
        let keyboardFrameInView = view.convert(keyboardFrameInScreen, from: nil)
        let bottomInset = view.bounds.maxY - keyboardFrameInView.origin.y
        
        var insets = TranscriptionTextBox.contentInset
        insets.bottom = bottomInset + 8   // add a little padding
        TranscriptionTextBox.contentInset = insets
        TranscriptionTextBox.scrollIndicatorInsets = insets
        
        if TranscriptionTextBox.isFirstResponder {
            TranscriptionTextBox.scrollRangeToVisible(TranscriptionTextBox.selectedRange)
        }
    }
    
    @objc private func keyboardWillHide(_ notification: Notification) {
        TranscriptionTextBox.contentInset = .zero
        TranscriptionTextBox.scrollIndicatorInsets = .zero
    }
    
    // MARK: - Actions
    @IBAction func BackButton(_ sender: Any) {
        Haptic.tap(intensity: 1.0)
        dismiss(animated: true, completion: nil)
    }
    
    // Button that shows the font size slider
    @IBAction func fontSizeButtonTapped(_ sender: UIButton) {
        Haptic.tap(intensity: 0.7)
        if (fontSizeSlider.isHidden) {
            showFontSizeSlider()
        } else {
            hideFontSizeSlider()
        }
    }
    
    // Button that shows the font selection list
    @IBAction func chooseFontButtonTapped(_ sender: UIView) {
        Haptic.tap(intensity: 0.7)
        
        let alert = UIAlertController(title: "Choose Font",
                                      message: nil,
                                      preferredStyle: .actionSheet)
        let currentSize = CGFloat(self.TranscriptionTextBox.font?.pointSize ?? self.selectedFontSize)
        for choice in fontChoices {
            let isSelected = (choice.title == selectedFontChoice.title)

            let action = UIAlertAction(title: choice.title, style: .default, handler: { [weak self] _ in
                guard let self = self else { return }

                self.selectedFontChoice = choice
                self.selectedFontSize = currentSize

                UIView.animate(withDuration: 0.1) {
                    self.applyFontAndLineSpacing()
                }

                // Update settings + persist
                self.persistFontSettings()
            })

            if isSelected {
                action.setValue(UIColor.systemBlue, forKey: "titleTextColor")
            }

            alert.addAction(action)
        }
        
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel, handler: nil))
        
        if let popover = alert.popoverPresentationController {
            popover.sourceView = sender
            popover.sourceRect = sender.bounds
        }
        
        present(alert, animated: true, completion: nil)
        // As soon as user taps a font, the action sheet auto-dismisses – no extra confirm needed.
    }
}
