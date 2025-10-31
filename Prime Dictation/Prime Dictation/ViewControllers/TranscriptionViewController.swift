import UIKit
import AVFoundation
import ProgressHUD

class TranscriptionViewController: UIViewController {
    var recordingManager: RecordingManager!
    
    var transcriptText: String?
    
    @IBOutlet weak var TranscriptionTextBox: UITextView!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        let services = AppServices.shared
        recordingManager = services.recordingManager
        
        TranscriptionTextBox.text = transcriptText
        
        // Option to press Done action item on keyboard toolbar to dismiss
        addDoneButtonToKeyboard()
        
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
    
    func displayAlert(title: String, message: String, handler: (@MainActor () -> Void)? = nil) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: {_ in
            handler?()
        }))
        present(alert, animated: true, completion: nil)
    }
    
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
        recordingManager.UpdateToggledTranscriptionText(newText: newText)
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
        
        // make sure the caret is visible
        if TranscriptionTextBox.isFirstResponder {
            TranscriptionTextBox.scrollRangeToVisible(TranscriptionTextBox.selectedRange)
        }
    }
    
    @objc private func keyboardWillHide(_ notification: Notification) {
        TranscriptionTextBox.contentInset = .zero
        TranscriptionTextBox.scrollIndicatorInsets = .zero
    }
    
    @IBAction func BackButton(_ sender: Any) {
        dismiss(animated: true, completion: nil)
    }
}
