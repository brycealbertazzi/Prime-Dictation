import UIKit
import GoogleSignIn

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let ctx = URLContexts.first else { return }
        let url = ctx.url

        // Convert scene options -> UIApplication-style options for your existing handler
        var options: [UIApplication.OpenURLOptionsKey: Any] = [:]
        if let sourceApp = ctx.options.sourceApplication {
            options[.sourceApplication] = sourceApp
        }
        if let annotation = ctx.options.annotation {
            options[.annotation] = annotation
        }

        let scheme = (url.scheme ?? "").lowercased()

        if scheme.hasPrefix("com.googleusercontent.apps") {
            _ = GIDSignIn.sharedInstance.handle(url)
            return
        }

        if scheme.hasPrefix("msauth") {
            _ = AppServices.shared.oneDriveManager.handleRedirect(url: url, options: options)
            return
        }

        if scheme.hasPrefix("db-") {
            _ = AppServices.shared.dropboxManager.handleRedirect(url: url)
            return
        }
    }

    // The other scene lifecycle methods can stay empty if you don’t need them
    func sceneDidBecomeActive(_ scene: UIScene) { }
    func sceneWillResignActive(_ scene: UIScene) { }
    func sceneWillEnterForeground(_ scene: UIScene) { }
    func sceneDidEnterBackground(_ scene: UIScene) { }
}
