import UIKit
import SafariServices

class InfoViewController: UIViewController {

    // MARK: - Data

    private struct HowToCard {
        let icon: String
        let action: String
        let detail: String
    }

    private let cards: [HowToCard] = [
        HowToCard(
            icon: "camera.rotate",
            action: "Flip Camera",
            detail: "Switch between front and back cameras to get the perfect angle on your athlete."
        ),
        HowToCard(
            icon: "magnifyingglass",
            action: "Zoom",
            detail: "TAP the zoom button to set a level (1.0x – 5.0x), or PINCH directly on the screen for smooth on-the-fly control."
        ),
        HowToCard(
            icon: "clock.arrow.circlepath",
            action: "Set Your Delay",
            detail: "Choose how far behind the replay follows the live swing — 5s, 7s, or 10s. Pick longer for more time to coach between reps."
        ),
        HowToCard(
            icon: "play.circle.fill",
            action: "Start Session",
            detail: "TAP PLAY when your athlete is ready. Loopr buffers and then plays back their swing at your chosen delay — continuously."
        ),
        HowToCard(
            icon: "pause.circle.fill",
            action: "Pause & Scrub",
            detail: "TAP the screen to reveal controls, then TAP PAUSE to freeze the replay. Drag the scrub bar to move through the swing frame by frame."
        ),
        HowToCard(
            icon: "scissors",
            action: "Clip & Save",
            detail: "While paused, TAP the scissors icon to enter Clip mode. Trim the handles to your best moment, then save it directly to your Photos library."
        ),
        HowToCard(
            icon: "arrow.counterclockwise.circle.fill",
            action: "Restart or End",
            detail: "TAP the restart icon to reset and run another delayed rep, or TAP the stop icon to end the session and return home."
        )
    ]

    // MARK: - UI

    private let scrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.alwaysBounceVertical = true
        sv.showsVerticalScrollIndicator = false
        return sv
    }()

    private let contentView: UIView = {
        let v = UIView()
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let logoImageView: UIImageView = {
        let iv = UIImageView()
        iv.contentMode = .scaleAspectFit
        iv.image = UIImage(named: "info-logo")
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()
    
    private let sloganLabel: UILabel = {
        let l = UILabel()
        l.text = "Instant Replay. Infinite Insight."
        l.font = UIFont.systemFont(ofSize: 18, weight: .bold)
        //l.textColor = UIColor.lightGray
        l.textColor = UIColor(red: 96/255, green: 73/255, blue: 157/255, alpha: 1.0)
        l.textAlignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let titleLabel: UILabel = {
        let l = UILabel()
        l.text = "How to Use Loopr"
        l.font = UIFont.systemFont(ofSize: 28, weight: .bold)
        l.textColor = .white
        l.textAlignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let cardsStack: UIStackView = {
        let sv = UIStackView()
        sv.axis = .vertical
        sv.spacing = 12
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }()

    private let supportLabel: UILabel = {
        let l = UILabel()
        l.text = "Need Help?"
        l.font = UIFont.systemFont(ofSize: 22, weight: .semibold)
        l.textColor = .white
        l.textAlignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let supportSubLabel: UILabel = {
        let l = UILabel()
        l.text = "We're happy to help — reach out any time."
        l.font = UIFont.systemFont(ofSize: 14)
        l.textColor = UIColor.lightGray
        l.textAlignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let emailButton: UIButton = {
        let b = UIButton(type: .system)
        b.setTitle("3up3down.help@gmail.com", for: .normal)
        b.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        b.setTitleColor(.systemBlue, for: .normal)
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let companyLogoButton: UIButton = {
        let b = UIButton(type: .custom)
        b.setImage(UIImage(named: "splash-company-logo"), for: .normal)
        b.imageView?.contentMode = .scaleAspectFit
        b.setContentHuggingPriority(.required, for: .horizontal)
        b.setContentCompressionResistancePriority(.required, for: .horizontal)
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let signsLogoButton: UIButton = {
        let b = UIButton(type: .custom)
        b.setImage(UIImage(named: "splash-signs-logo"), for: .normal)
        b.imageView?.contentMode = .scaleAspectFit
        b.setContentHuggingPriority(.required, for: .horizontal)
        b.setContentCompressionResistancePriority(.required, for: .horizontal)
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let logosStack: UIStackView = {
        let sv = UIStackView()
        sv.axis = .vertical
        sv.spacing = 24
        sv.alignment = .center
        sv.distribution = .equalSpacing
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }()

    private let versionLabel: UILabel = {
        let l = UILabel()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        l.text = "Version \(version) (Build \(build))"
        l.font = UIFont.systemFont(ofSize: 12, weight: .medium)
        l.textColor = UIColor.darkGray
        l.textAlignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

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

    private let accentColor = UIColor(red: 96/255, green: 73/255, blue: 157/255, alpha: 1.0)

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupUI()
        applyLogoAspectRatios()
    }

    /// Reads each logo image's actual pixel size and pins each button's width
    /// to that aspect ratio at 60pt height — so both logos share the same height
    /// regardless of how wide their artwork is.
    private func applyLogoAspectRatios() {
        let height: CGFloat = 60

        // Company logo: fixed height, width from its aspect ratio
        if let companyImg = UIImage(named: "splash-company-logo"), companyImg.size.height > 0 {
            let companyWidth = height * (companyImg.size.width / companyImg.size.height)
            companyLogoButton.widthAnchor.constraint(equalToConstant: companyWidth).isActive = true
            companyLogoButton.heightAnchor.constraint(equalToConstant: height).isActive = true

            // Signs logo: same width, height derived from its own aspect ratio at that width
            signsLogoButton.widthAnchor.constraint(equalToConstant: companyWidth).isActive = true
            if let signsImg = UIImage(named: "splash-signs-logo"), signsImg.size.width > 0 {
                let signsHeight = companyWidth * (signsImg.size.height / signsImg.size.width)
                signsLogoButton.heightAnchor.constraint(equalToConstant: signsHeight).isActive = true
            }
        }
    }

    // MARK: - Setup

    private func setupUI() {
        view.addSubview(scrollView)
        view.addSubview(closeButton)
        scrollView.addSubview(contentView)

        // Build cards and add to stack – no number parameter needed
        for card in cards {
            cardsStack.addArrangedSubview(makeCardView(card: card))
        }

        [logoImageView, titleLabel, sloganLabel,
         cardsStack, supportLabel, supportSubLabel, emailButton,
         logosStack, versionLabel].forEach { contentView.addSubview($0) }

        NSLayoutConstraint.activate([
            // Scroll view – full screen
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Close button – floats top right
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),

            // Content view
            contentView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            contentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            // Logo
            logoImageView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 40),
            logoImageView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            logoImageView.widthAnchor.constraint(equalToConstant: 160),
            logoImageView.heightAnchor.constraint(equalToConstant: 160),

            // Subtitle
            sloganLabel.topAnchor.constraint(equalTo: logoImageView.bottomAnchor, constant: 6),
            sloganLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            sloganLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            // Title
            titleLabel.topAnchor.constraint(equalTo: sloganLabel.bottomAnchor, constant: 22),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            // Cards stack – centred, capped at 600pt wide for landscape
            cardsStack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 24),
            cardsStack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            cardsStack.widthAnchor.constraint(lessThanOrEqualToConstant: 600),
            cardsStack.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, constant: -32),
            cardsStack.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: 16),

            // Support section
            supportLabel.topAnchor.constraint(equalTo: cardsStack.bottomAnchor, constant: 38),
            supportLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),

            supportSubLabel.topAnchor.constraint(equalTo: supportLabel.bottomAnchor, constant: 6),
            supportSubLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            supportSubLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            emailButton.topAnchor.constraint(equalTo: supportSubLabel.bottomAnchor, constant: 10),
            emailButton.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),

            // Logos stacked – centred, widths and heights set from image aspect ratios at runtime
            logosStack.topAnchor.constraint(equalTo: emailButton.bottomAnchor, constant: 50),
            logosStack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),

            // Version
            versionLabel.topAnchor.constraint(equalTo: logosStack.bottomAnchor, constant: 32),
            versionLabel.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            versionLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10)
        ])

        // Build logos stack
        logosStack.addArrangedSubview(companyLogoButton)
        logosStack.addArrangedSubview(signsLogoButton)

        companyLogoButton.addTarget(self, action: #selector(companyLogoTapped), for: .touchUpInside)
        signsLogoButton.addTarget(self, action: #selector(signsLogoTapped), for: .touchUpInside)
        emailButton.addTarget(self, action: #selector(emailTapped), for: .touchUpInside)
    }

    // MARK: - Card Factory

    private func makeCardView(card: HowToCard) -> UIView {
        let container = UIView()
        container.backgroundColor = UIColor.white.withAlphaComponent(0.06)
        container.layer.cornerRadius = 16
        container.layer.borderWidth = 1
        container.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
        container.translatesAutoresizingMaskIntoConstraints = false

        // Icon only – no number badge
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 26, weight: .medium)
        let iconView = UIImageView(image: UIImage(systemName: card.icon, withConfiguration: iconConfig))
        iconView.tintColor = accentColor
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false

        // Action label
        let actionLabel = UILabel()
        actionLabel.text = card.action
        actionLabel.font = UIFont.systemFont(ofSize: 16, weight: .bold)
        actionLabel.textColor = .white
        actionLabel.translatesAutoresizingMaskIntoConstraints = false

        // Detail label
        let detailLabel = UILabel()
        detailLabel.text = card.detail
        detailLabel.font = UIFont.systemFont(ofSize: 14, weight: .regular)
        detailLabel.textColor = UIColor.lightGray
        detailLabel.numberOfLines = 0
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        let textStack = UIStackView(arrangedSubviews: [actionLabel, detailLabel])
        textStack.axis = .vertical
        textStack.spacing = 4
        textStack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(iconView)
        container.addSubview(textStack)

        NSLayoutConstraint.activate([
            // Icon – fixed width, vertically centred
            iconView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            iconView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 32),
            iconView.heightAnchor.constraint(equalToConstant: 32),

            // Text stack – fills remaining space
            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 14),
            textStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            textStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 16),
            textStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16)
        ])

        return container
    }

    // MARK: - Actions

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    @objc private func companyLogoTapped() {
        guard let url = URL(string: "https://www.3up3down.io/?utm_source=loopr-ios") else { return }
        let safari = SFSafariViewController(url: url)
        safari.preferredControlTintColor = accentColor
        present(safari, animated: true)
    }

    @objc private func signsLogoTapped() {
        guard let url = URL(string: "https://signs.3up3down.io/?utm_source=loopr-ios") else { return }
        let safari = SFSafariViewController(url: url)
        safari.preferredControlTintColor = accentColor
        present(safari, animated: true)
    }

    @objc private func emailTapped() {
        let email = "3up3down.help@gmail.com"
        if let url = URL(string: "mailto:\(email)") {
            if UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url)
            } else {
                UIPasteboard.general.string = email
                let alert = UIAlertController(
                    title: "Email Copied",
                    message: "Email address copied to clipboard",
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
        }
    }
}
