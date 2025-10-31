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
        
        //Option to press Done action item on keyboard toolbar to dismiss
        addDoneButtonToKeyboard()
        
        //Option tap to dismiss keyboard
        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false   // so taps on buttons still work
        view.addGestureRecognizer(tap)
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
        guard let newText = TranscriptionTextBox.text else {
            ProgressHUD.failed("Failed to update transcription")
            return
        }
        recordingManager.UpdateToggledTranscriptionText(newText: newText)
    }
    
    @IBAction func BackButton(_ sender: Any) {
        dismiss(animated: true, completion: nil)
    }
}
