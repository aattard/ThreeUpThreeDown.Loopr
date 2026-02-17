import UIKit
import StoreKit

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - PaywallViewController
// ─────────────────────────────────────────────────────────────────────────────
// Presented modally (fullScreen) when the user taps PLAY after their trial
// has expired. Styled to match InfoViewController – black background, white
// text, same close-button pattern.
// ─────────────────────────────────────────────────────────────────────────────

class PaywallViewController: UIViewController {

    // Called by HomeViewController to know when to proceed with the session
    var onUnlocked: (() -> Void)?

    // ─────────────────────────────────────────────────────────────────────
    // MARK: - UI Elements
    // ─────────────────────────────────────────────────────────────────────

    private let scrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.alwaysBounceVertical = true
        return sv
    }()

    private let contentView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    // App logo – reuses the same asset as HomeViewController
    private let logoImageView: UIImageView = {
        let iv = UIImageView()
        iv.image = UIImage(named: "inapp-logo")
        iv.contentMode = .scaleAspectFit
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private let headlineLabel: UILabel = {
        let l = UILabel()
        l.text = "Unlock Loopr"
        l.font = UIFont.systemFont(ofSize: 32, weight: .bold)
        l.textColor = .white
        l.textAlignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private lazy var subheadlineLabel: UILabel = {
        let l = UILabel()
        l.font = UIFont.systemFont(ofSize: 18, weight: .regular)
        l.textColor = UIColor.lightGray
        l.textAlignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    // Feature bullet list
    private let featuresLabel: UILabel = {
        let l = UILabel()
        l.numberOfLines = 0
        l.textAlignment = .center
        l.textColor = .white
        l.font = UIFont.systemFont(ofSize: 17)

        let features = """
        ✓  Delayed video replay for swing analysis
        ✓  Scrub through your replay frame-by-frame
        ✓  Clip and save your best swings to Photos
        ✓  Front & back camera support
        ✓  Adjustable delay (5s, 7s, 10s)
        ✓  Smooth pinch-to-zoom
        ✓  One-time purchase – no subscription
        ✓  Yours forever, on every device you own
        """
        l.text = features
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    // Main purchase CTA – price is injected once the StoreKit product loads
    private let purchaseButton: UIButton = {
        let b = UIButton(type: .system)
        b.setTitle("Loading…", for: .normal)
        b.titleLabel?.font = UIFont.systemFont(ofSize: 20, weight: .bold)
        b.setTitleColor(.white, for: .normal)
        b.backgroundColor = UIColor(red: 96/255, green: 73/255, blue: 157/255, alpha: 1.0)
        b.layer.cornerRadius = 12
        b.layer.borderWidth = 1
        b.layer.borderColor = UIColor.black.withAlphaComponent(1.0).cgColor
        b.clipsToBounds = true
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let priceNoteLabel: UILabel = {
        let l = UILabel()
        l.text = "One-time purchase · No subscription · No hidden fees"
        l.font = UIFont.systemFont(ofSize: 13)
        l.textColor = UIColor.lightGray
        l.textAlignment = .center
        l.numberOfLines = 0
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let restoreButton: UIButton = {
        let b = UIButton(type: .system)
        b.setTitle("Already purchased? Restore", for: .normal)
        b.titleLabel?.font = UIFont.systemFont(ofSize: 15)
        b.setTitleColor(.systemBlue, for: .normal)
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    // Terms / privacy note required by App Store guidelines
    private let legalLabel: UILabel = {
        let l = UILabel()
        l.text = "Payment is charged to your Apple ID at confirmation of purchase."
        l.font = UIFont.systemFont(ofSize: 12)
        l.textColor = UIColor.darkGray
        l.textAlignment = .center
        l.numberOfLines = 0
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    // Activity spinner shown during purchase / restore
    private let activityIndicator: UIActivityIndicatorView = {
        let ai = UIActivityIndicatorView(style: .large)
        ai.color = .white
        ai.hidesWhenStopped = true
        ai.translatesAutoresizingMaskIntoConstraints = false
        return ai
    }()

    // Close / dismiss button (top-right, matches InfoViewController)
    // Hidden if the trial has expired so the user MUST make a decision.
    // Set showCloseButton = true to allow dismissal (e.g. during active trial).
    var showCloseButton: Bool = false

    private lazy var closeButton: UIButton = {
        let b = UIButton(type: .system)
        b.setTitle("✕", for: .normal)
        b.titleLabel?.font = UIFont.systemFont(ofSize: 28, weight: .regular)
        b.setTitleColor(.white, for: .normal)
        b.backgroundColor = UIColor.systemGray.withAlphaComponent(0.3)
        b.layer.cornerRadius = 22
        b.translatesAutoresizingMaskIntoConstraints = false
        b.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        return b
    }()

    // ─────────────────────────────────────────────────────────────────────
    // MARK: - Lifecycle
    // ─────────────────────────────────────────────────────────────────────

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupUI()
        refreshPurchaseButton()

        // Set subheadline based on actual access state
        switch PurchaseManager.shared.accessState {
        case .trial(let days):
            let dayWord = days == 1 ? "day" : "days"
            subheadlineLabel.text = "You have \(days) free \(dayWord) remaining."
        case .expired:
            subheadlineLabel.text = "Your free trial has ended."
        case .purchased:
            subheadlineLabel.text = "Thanks for supporting Loopr! ⚾️"
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: - Layout
    // ─────────────────────────────────────────────────────────────────────

    private func setupUI() {
        view.addSubview(scrollView)
        view.addSubview(activityIndicator)

        if showCloseButton {
            view.addSubview(closeButton)
            NSLayoutConstraint.activate([
                closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
                closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
                closeButton.widthAnchor.constraint(equalToConstant: 44),
                closeButton.heightAnchor.constraint(equalToConstant: 44)
            ])
        }

        scrollView.addSubview(contentView)
        [logoImageView, headlineLabel, subheadlineLabel,
         featuresLabel, purchaseButton, priceNoteLabel,
         restoreButton, legalLabel].forEach { contentView.addSubview($0) }

        NSLayoutConstraint.activate([
            // Scroll view fills screen
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Content view
            contentView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            // Logo
            logoImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 60),
            logoImageView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            logoImageView.widthAnchor.constraint(equalToConstant: 160),
            logoImageView.heightAnchor.constraint(equalToConstant: 160),

            // Headline
            headlineLabel.topAnchor.constraint(equalTo: logoImageView.bottomAnchor, constant: 24),
            headlineLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            headlineLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),

            // Subheadline
            subheadlineLabel.topAnchor.constraint(equalTo: headlineLabel.bottomAnchor, constant: 8),
            subheadlineLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            subheadlineLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),

            // Features
            featuresLabel.topAnchor.constraint(equalTo: subheadlineLabel.bottomAnchor, constant: 36),
            featuresLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 32),
            featuresLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -32),

            // Purchase button
            purchaseButton.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            purchaseButton.topAnchor.constraint(equalTo: featuresLabel.bottomAnchor, constant: 44),
            purchaseButton.heightAnchor.constraint(equalToConstant: 56),

            // Price note
            priceNoteLabel.topAnchor.constraint(equalTo: purchaseButton.bottomAnchor, constant: 12),
            priceNoteLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            priceNoteLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),

            // Restore button
            restoreButton.topAnchor.constraint(equalTo: priceNoteLabel.bottomAnchor, constant: 20),
            restoreButton.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),

            // Legal
            legalLabel.topAnchor.constraint(equalTo: restoreButton.bottomAnchor, constant: 24),
            legalLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            legalLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            legalLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -40),

            // Spinner – centred over the whole view
            activityIndicator.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            activityIndicator.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        purchaseButton.addTarget(self, action: #selector(purchaseTapped), for: .touchUpInside)
        restoreButton.addTarget(self, action: #selector(restoreTapped), for: .touchUpInside)
        
        purchaseButton.contentEdgeInsets = UIEdgeInsets(top: 0, left: 32, bottom: 0, right: 32)
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: - Button State
    // ─────────────────────────────────────────────────────────────────────

    /// Updates the purchase button title with the real price from StoreKit.
    private func refreshPurchaseButton() {
        if let product = PurchaseManager.shared.product {
            purchaseButton.setTitle("Unlock Loopr – \(product.displayPrice)", for: .normal)
            purchaseButton.isEnabled = true
        } else {
            purchaseButton.setTitle("Unlock Loopr – $1.99", for: .normal)
            purchaseButton.isEnabled = true  // Still allow tap; StoreKit will surface any error
        }
    }

    private func setLoading(_ loading: Bool) {
        if loading {
            activityIndicator.startAnimating()
            purchaseButton.isEnabled = false
            restoreButton.isEnabled = false
        } else {
            activityIndicator.stopAnimating()
            purchaseButton.isEnabled = true
            restoreButton.isEnabled = true
        }
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: - Actions
    // ─────────────────────────────────────────────────────────────────────

    @objc private func purchaseTapped() {
        print("💳 Purchase tapped")
        setLoading(true)

        // Wire up the success callback before initiating
        PurchaseManager.shared.onPurchaseSuccess = { [weak self] in
            guard let self else { return }
            self.setLoading(false)
            self.showSuccessAndDismiss()
        }

        Task {
            do {
                try await PurchaseManager.shared.purchase()
            } catch {
                await MainActor.run {
                    self.setLoading(false)
                    self.showError(error.localizedDescription)
                }
            }
            await MainActor.run { self.setLoading(false) }
        }
    }

    @objc private func restoreTapped() {
        print("🔄 Restore tapped")
        setLoading(true)

        PurchaseManager.shared.onPurchaseSuccess = { [weak self] in
            guard let self else { return }
            self.setLoading(false)
            self.showSuccessAndDismiss()
        }

        Task {
            await PurchaseManager.shared.restorePurchases()
            await MainActor.run {
                self.setLoading(false)
                // If restore didn't fire onPurchaseSuccess, nothing was found
                if !PurchaseManager.shared.canStartSession() {
                    self.showError("No previous purchase found for this Apple ID.")
                }
            }
        }
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    // ─────────────────────────────────────────────────────────────────────
    // MARK: - Post-Purchase Flow
    // ─────────────────────────────────────────────────────────────────────

    private func showSuccessAndDismiss() {
        let alert = UIAlertController(
            title: "You're all set! ⚾️",
            message: "Thank you for supporting Loopr. Enjoy your sessions!",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Let's go!", style: .default) { [weak self] _ in
            self?.dismiss(animated: true) {
                self?.onUnlocked?()
            }
        })
        present(alert, animated: true)
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: "Something went wrong", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
