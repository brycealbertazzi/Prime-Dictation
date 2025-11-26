import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {

        // Make sure we have a UIWindowScene
        guard let windowScene = scene as? UIWindowScene else { return }

        // Create a new window for this scene
        let window = UIWindow(windowScene: windowScene)

        // Load your "Main" storyboard
        let storyboard = UIStoryboard(name: "Main", bundle: nil)

        // Instantiate the initial view controller from Main.storyboard
        let rootVC = storyboard.instantiateInitialViewController()!

        // Hook it all up
        window.rootViewController = rootVC
        self.window = window
        window.makeKeyAndVisible()
    }

    // The other scene lifecycle methods can stay empty if you don’t need them
    func sceneDidBecomeActive(_ scene: UIScene) { }
    func sceneWillResignActive(_ scene: UIScene) { }
    func sceneWillEnterForeground(_ scene: UIScene) { }
    func sceneDidEnterBackground(_ scene: UIScene) { }
}
