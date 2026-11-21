import UIKit
import Capacitor

/// The app's one screen: Capacitor's web view with Brain Bento's native plugin plugged in.
class BBViewController: CAPBridgeViewController {
    override func capacitorDidLoad() {
        bridge?.registerPluginInstance(BBNativePlugin())
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // the page's own background color, so there's no flash of a different shade while it loads
        let paper = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 14 / 255, green: 15 / 255, blue: 18 / 255, alpha: 1)
                : UIColor(red: 243 / 255, green: 244 / 255, blue: 246 / 255, alpha: 1)
        }
        webView?.backgroundColor = paper
        webView?.scrollView.backgroundColor = paper
    }
}
