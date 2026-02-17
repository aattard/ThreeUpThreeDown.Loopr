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
    }
    
    func showMainApp() {
        // Transition to main app
        guard let homeVC = homeVC else { return }
        let navController = UINavigationController(rootViewController: homeVC)
        navController.setNavigationBarHidden(true, animated: false)
        window?.rootViewController = navController
        
        // Clean up splash reference
        splashVC = nil
    }
    
    private func prewarmApp() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)

        if status == .notDetermined {
            // First launch — request permission
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        print("✅ Camera access granted")
                        self.setupHomeViewController()
                    } else {
                        print("❌ Camera access denied")
                        // Still set up HomeVC so splash can transition
                        // HomeVC will show the alert once it appears
                        self.setupHomeViewController()
                    }
                }
            }
        } else {
            // Permission already determined (granted or denied) — set up immediately
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
        // Create HomeVC and set callback
        homeVC = HomeViewController()
        homeVC?.onCameraPreviewReady = { [weak self] in
            print("✅ Camera preview ready, dismissing splash")
            self?.splashVC?.cameraIsReady()
        }
        
        // Trigger the view to load (which starts camera setup)
        _ = homeVC?.view
    }
    
    func sceneDidDisconnect(_ scene: UIScene) {}
    func sceneDidBecomeActive(_ scene: UIScene) {}
    func sceneWillResignActive(_ scene: UIScene) {}
    func sceneWillEnterForeground(_ scene: UIScene) {}
    func sceneDidEnterBackground(_ scene: UIScene) {}
}
