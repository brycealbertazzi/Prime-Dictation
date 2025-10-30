import UIKit
import AVFoundation
import SwiftyDropbox
import ProgressHUD
import FirebaseAuth

class TranscriptionViewController: UIViewController {
    var transcriptText: String?
    
    @IBOutlet weak var TranscriptionTextBox: UITextView!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        TranscriptionTextBox.text = transcriptText
    }
    
    func displayAlert(title: String, message: String, handler: (@MainActor () -> Void)? = nil) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default, handler: {_ in
            handler?()
        }))
        present(alert, animated: true, completion: nil)
    }
    
    @IBAction func BackButton(_ sender: Any) {
        dismiss(animated: true, completion: nil)
    }
}
