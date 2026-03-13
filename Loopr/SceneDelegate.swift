import UIKit
import AVFoundation

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    
    var window: UIWindow?
    private var splashVC: SplashViewController?
    private var homeVC: HomeViewController?
    
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = (scene as? UIWindowScene) else { return }
        window = UIWindow(windowScene: windowScene)
        
        // Create splash screen
        splashVC = SplashViewController()
        window?.rootViewController = splashVC
        window?.makeKeyAndVisible()
        
        // Pre-warm camera and create HomeVC in background
        prewarmApp()
        
        // Handle Universal Link if app was launched cold via one
        if let userActivity = connectionOptions.userActivities.first,
           userActivity.activityType == NSUserActivityTypeBrowsingWeb,
           let url = userActivity.webpageURL,
           url.path.hasPrefix("/start") {
            pendingUniversalLink = true
        }
    }
    
    // MARK: - Universal Links
    
    /// Flags a /start Universal Link that arrived before HomeVC was ready.
    /// HomeViewController checks this once it finishes loading and clears it.
    var pendingUniversalLink: Bool = false
    
    func scene(_ scene: UIScene, continue userActivity: NSUserActivity) {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = userActivity.webpageURL,
              url.path.hasPrefix("/start") else { return }
        
        // If HomeVC is already live, fire immediately
        if let homeVC = homeVC {
            homeVC.handleUniversalLinkStart()
        } else {
            // App is still warming up — flag it for HomeVC to pick up
            pendingUniversalLink = true
        }
    }
    
    // MARK: - App Setup
    
    func showMainApp() {
        guard let homeVC = homeVC else { return }
        let navController = UINavigationController(rootViewController: homeVC)
        navController.setNavigationBarHidden(true, animated: false)
        window?.rootViewController = navController
        splashVC = nil
    }
    
    private func prewarmApp() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)

        if status == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        print("✅ Camera access granted")
                        self.setupHomeViewController()
                    } else {
                        print("❌ Camera access denied")
                        self.setupHomeViewController()
                    }
                }
            }
        } else {
            DispatchQueue.main.async {
                self.setupHomeViewController()
            }
        }

        DispatchQueue.global(qos: .userInitiated).async {
            _ = Settings.shared
            DispatchQueue.main.async {
                print("✅ App pre-warming complete")
            }
        }
    }
    
    private func setupHomeViewController() {
        homeVC = HomeViewController()
        homeVC?.onCameraPreviewReady = { [weak self] in
            print("✅ Camera preview ready, dismissing splash")
            self?.splashVC?.cameraIsReady()
        }
        _ = homeVC?.view
    }
    
    func sceneDidDisconnect(_ scene: UIScene) {}
    func sceneDidBecomeActive(_ scene: UIScene) {}
    func sceneWillResignActive(_ scene: UIScene) {}
    func sceneWillEnterForeground(_ scene: UIScene) {}
    func sceneDidEnterBackground(_ scene: UIScene) {}
}
