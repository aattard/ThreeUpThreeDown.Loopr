import UIKit
import AVFoundation
import Photos
import UniformTypeIdentifiers

final class SplitVideoView: UIViewController {

    // MARK: - Public API

    var leftURL: URL?
    var rightURL: URL?

    /// Called when user closes this view so the owner can return to RecordedVideoView
    /// and clean up temp files.
    var onDismiss: (() -> Void)?
    
    var onRestartRequested: (() -> Void)?
    var onStopSessionRequested: (() -> Void)?

    // MARK: - Private AV state

    private var leftPlayer: AVPlayer?
    private var rightPlayer: AVPlayer?

    private var leftTimeObserver: Any?
    private var rightTimeObserver: Any?
    private var linkedBoundaryObserver: Any?  // fires precisely at end of linked window

    private var isLinked: Bool = false
    private var isEditMode: Bool = false
    private var controlsVisible: Bool = true
    private var isSharedPlaying: Bool = false
    private var syncOffsetSeconds: Double = 0.0
    private var linkStartLeft:  Double = 0.0  // left position when link was established
    private var linkStartRight: Double = 0.0  // right position when link was established
    // Overlap window expressed as seconds relative to the sync point (linkStart*)
    // Negative = how far back both videos can go; Positive = how far forward
    private var linkedWindowBack:    Double = 0.0  // seconds before sync point (≥0)
    private var linkedWindowForward: Double = 0.0  // seconds after  sync point (≥0)
    // Total window duration = linkedWindowBack + linkedWindowForward
    private var linkedWindowDuration: Double { linkedWindowBack + linkedWindowForward }

    // MARK: - UI

    private let closeButtonContainer: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        v.layer.cornerRadius = 32 // 64 / 2
        v.translatesAutoresizingMaskIntoConstraints = false
        v.clipsToBounds = true
        return v
    }()

    private let closeButton: UIButton = {
        let b = UIButton(type: .system)
        let cfg = UIImage.SymbolConfiguration(pointSize: 28, weight: .regular) // Match right side exactly
        let img = UIImage(systemName: "chevron.backward.circle", withConfiguration: cfg)
        b.setImage(img, for: .normal)
        //b.setTitle(" Back", for: .normal)
        b.tintColor = .white
        b.setTitleColor(.white, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        b.backgroundColor = .clear
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let linkButton: UIButton = {
        let b = UIButton(type: .system)
        let cfg = UIImage.SymbolConfiguration(pointSize: 28, weight: .regular) // Match right side exactly
        b.setImage(UIImage(systemName: "link.circle", withConfiguration: cfg), for: .normal)
        b.setTitle(" Link", for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        b.tintColor = .systemGray
        b.setTitleColor(.systemGray, for: .normal)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.isEnabled = false
        return b
    }()
    
    private let editButton: UIButton = {
        let b = UIButton(type: .system)
        let cfg = UIImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        b.setImage(UIImage(systemName: "film.circle", withConfiguration: cfg), for: .normal)
        b.setTitle(" Edit", for: .normal)
        b.tintColor = .systemGray
        b.setTitleColor(.systemGray, for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        b.backgroundColor = .clear
        b.isEnabled = false
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let topRightContainer: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        v.layer.cornerRadius = 32
        v.translatesAutoresizingMaskIntoConstraints = false
        v.clipsToBounds = true
        return v
    }()

    private let restartButton: UIButton = {
        let b = UIButton(type: .system)
        let cfg = UIImage.SymbolConfiguration(pointSize: 32, weight: .bold) // Changed to 32
        b.setImage(UIImage(systemName: "arrow.clockwise.circle.fill", withConfiguration: cfg), for: .normal)
        b.tintColor = .systemGreen
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let stopSessionButton: UIButton = {
        let b = UIButton(type: .system)
        let cfg = UIImage.SymbolConfiguration(pointSize: 32, weight: .bold) // Changed to 32
        b.setImage(UIImage(systemName: "xmark.circle.fill", withConfiguration: cfg), for: .normal)
        b.tintColor = .systemRed
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let stackView: UIStackView = {
        let s = UIStackView()
        s.axis = .horizontal
        s.alignment = .fill
        s.distribution = .fillEqually
        s.spacing = 1
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }()

    private let leftContainer = VideoPaneView()
    private let rightContainer = VideoPaneView()

    // MARK: - Shared UI
    private let sharedControlsContainer: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        v.layer.cornerRadius = 24
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true // Hidden by default
        return v
    }()
    
    private let sharedPlayPauseButton: UIButton = {
        let b = UIButton(type: .system)
        let cfg = UIImage.SymbolConfiguration(pointSize: 28, weight: .bold)
        b.setImage(UIImage(systemName: "play.circle.fill", withConfiguration: cfg), for: .normal)
        b.tintColor = .white
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()
    
    private let sharedScrubSlider: UISlider = {
        let s = UISlider()
        
        // 20x20 thumb - stroke fits PERFECTLY inside slider bounds
        let thumbSize: CGFloat = 20
        let strokeWidth: CGFloat = 1.5  // Thinner stroke
        let padding: CGFloat = 1.5      // Extra safety margin

        let thumbImage = UIGraphicsImageRenderer(size: CGSize(width: thumbSize, height: thumbSize))
            .image { context in
                // White fill (smaller circle)
                let fillSize = thumbSize - (strokeWidth * 2) - (padding * 2)
                let fillRect = CGRect(x: padding + strokeWidth, y: padding + strokeWidth,
                                     width: fillSize, height: fillSize)
                UIColor.white.setFill()
                UIBezierPath(ovalIn: fillRect).fill()
                
                // Yellow stroke (slightly inset)
                let strokeRect = CGRect(x: padding, y: padding,
                                       width: thumbSize - (padding * 2),
                                       height: thumbSize - (padding * 2))
                UIColor.systemYellow.setStroke()
                let strokePath = UIBezierPath(ovalIn: strokeRect)
                strokePath.lineWidth = strokeWidth
                strokePath.lineCapStyle = .round
                strokePath.lineJoinStyle = .round
                strokePath.stroke()
            }

        s.setThumbImage(thumbImage.withRenderingMode(.alwaysOriginal), for: .normal)

        s.minimumTrackTintColor = .white
        s.maximumTrackTintColor = UIColor(red: 96/255, green: 73/255, blue: 157/255, alpha: 1)
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }()

    private let sharedTimeLabel: UILabel = {
        let l = UILabel()
        l.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        l.textColor = .white
        l.text = "00:00.00"
        l.textAlignment = .right
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()
    
    // MARK: - Lifecycle

    init(leftURL: URL?, rightURL: URL?) {
        self.leftURL = leftURL
        self.rightURL = rightURL
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        setupUI()
        setupActions()
        setupTapGesture()
        configurePlayers()
        
        // Listen for Remove button taps
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRemoveNotification(_:)),
            name: Notification.Name("VideoPaneViewRemoveTapped"),
            object: nil
        )
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateStackAxisForOrientation()
    }

    deinit {
        tearDownPlayers()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - UI Setup

    private func setupUI() {
        view.addSubview(stackView)
        
        view.addSubview(closeButtonContainer)
        closeButtonContainer.addSubview(closeButton)
        closeButtonContainer.addSubview(linkButton)
        closeButtonContainer.addSubview(editButton)
        
        view.addSubview(topRightContainer)
        topRightContainer.addSubview(restartButton)
        topRightContainer.addSubview(stopSessionButton)

        stackView.addArrangedSubview(leftContainer)
        stackView.addArrangedSubview(rightContainer)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            // Left Container (Back & Link & Edit button)
            closeButtonContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            closeButtonContainer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            closeButtonContainer.heightAnchor.constraint(equalToConstant: 64),

            closeButton.leadingAnchor.constraint(equalTo: closeButtonContainer.leadingAnchor, constant: 10),
            closeButton.centerYAnchor.constraint(equalTo: closeButtonContainer.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),

            editButton.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 4),
            editButton.centerYAnchor.constraint(equalTo: closeButtonContainer.centerYAnchor),
            editButton.heightAnchor.constraint(equalToConstant: 44),

            linkButton.leadingAnchor.constraint(equalTo: editButton.trailingAnchor, constant: 12),
            linkButton.centerYAnchor.constraint(equalTo: closeButtonContainer.centerYAnchor),
            linkButton.heightAnchor.constraint(equalToConstant: 44),
            linkButton.trailingAnchor.constraint(equalTo: closeButtonContainer.trailingAnchor, constant: -16),

            // Top Right Container
            topRightContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            topRightContainer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            topRightContainer.heightAnchor.constraint(equalToConstant: 64),
            topRightContainer.widthAnchor.constraint(equalToConstant: 108),

            restartButton.leadingAnchor.constraint(equalTo: topRightContainer.leadingAnchor, constant: 10),
            restartButton.centerYAnchor.constraint(equalTo: topRightContainer.centerYAnchor),
            restartButton.widthAnchor.constraint(equalToConstant: 44),
            restartButton.heightAnchor.constraint(equalToConstant: 44),

            stopSessionButton.trailingAnchor.constraint(equalTo: topRightContainer.trailingAnchor, constant: -10),
            stopSessionButton.centerYAnchor.constraint(equalTo: topRightContainer.centerYAnchor),
            stopSessionButton.widthAnchor.constraint(equalToConstant: 44),
            stopSessionButton.heightAnchor.constraint(equalToConstant: 44)
        ])
        
        linkButton.setContentHuggingPriority(.required, for: .horizontal)
        linkButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        
        // Add Shared Controls to view
        view.addSubview(sharedControlsContainer)
        sharedControlsContainer.addSubview(sharedPlayPauseButton)
        sharedControlsContainer.addSubview(sharedScrubSlider)
        sharedControlsContainer.addSubview(sharedTimeLabel)

        NSLayoutConstraint.activate([
            sharedControlsContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            sharedControlsContainer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            sharedControlsContainer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            sharedControlsContainer.heightAnchor.constraint(equalToConstant: 48),

            sharedPlayPauseButton.leadingAnchor.constraint(equalTo: sharedControlsContainer.leadingAnchor, constant: 8),
            sharedPlayPauseButton.centerYAnchor.constraint(equalTo: sharedControlsContainer.centerYAnchor),
            sharedPlayPauseButton.widthAnchor.constraint(equalToConstant: 32),
            sharedPlayPauseButton.heightAnchor.constraint(equalToConstant: 32),

            sharedTimeLabel.trailingAnchor.constraint(equalTo: sharedControlsContainer.trailingAnchor, constant: -12),
            sharedTimeLabel.centerYAnchor.constraint(equalTo: sharedControlsContainer.centerYAnchor),
            sharedTimeLabel.widthAnchor.constraint(equalToConstant: 72),

            sharedScrubSlider.leadingAnchor.constraint(equalTo: sharedPlayPauseButton.trailingAnchor, constant: 10),
            sharedScrubSlider.trailingAnchor.constraint(equalTo: sharedTimeLabel.leadingAnchor, constant: -10),
            sharedScrubSlider.centerYAnchor.constraint(equalTo: sharedControlsContainer.centerYAnchor)
        ])
    }

    private func setupActions() {
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        linkButton.addTarget(self, action: #selector(linkTapped), for: .touchUpInside)
        editButton.addTarget(self, action: #selector(editTapped), for: .touchUpInside)

        restartButton.addTarget(self, action: #selector(restartTapped), for: .touchUpInside)
        stopSessionButton.addTarget(self, action: #selector(stopSessionTapped), for: .touchUpInside)

        leftContainer.addButton.addTarget(self, action: #selector(addLeftTapped), for: .touchUpInside)
        rightContainer.addButton.addTarget(self, action: #selector(addRightTapped), for: .touchUpInside)

        leftContainer.scrubSlider.addTarget(self, action: #selector(leftSliderChanged(_:)), for: .valueChanged)
        rightContainer.scrubSlider.addTarget(self, action: #selector(rightSliderChanged(_:)), for: .valueChanged)
        
        sharedPlayPauseButton.addTarget(self, action: #selector(sharedPlayPauseTapped), for: .touchUpInside)
        sharedScrubSlider.addTarget(self, action: #selector(sharedSliderChanged(_:)), for: .valueChanged)
    }
    
    private func setupTapGesture() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleViewTap))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        view.addGestureRecognizer(tap)
    }

    @objc private func handleViewTap() {
        controlsVisible.toggle()
        UIView.animate(withDuration: 0.25) {
            self.closeButtonContainer.alpha = self.controlsVisible ? 1 : 0
            self.topRightContainer.alpha = self.controlsVisible ? 1 : 0
        }
    }

    private func updateLinkButtonState() {
        let bothLoaded = (leftPlayer != nil && rightPlayer != nil)
        let eitherLoaded = (leftPlayer != nil || rightPlayer != nil)

        if !bothLoaded && isLinked {
            linkTapped()
        }

        linkButton.isEnabled = bothLoaded
        if bothLoaded {
            let color: UIColor = isLinked ? .systemYellow : .white
            linkButton.tintColor = color
            linkButton.setTitleColor(color, for: .normal)
        } else {
            linkButton.tintColor = .systemGray
            linkButton.setTitleColor(.systemGray, for: .normal)
        }

        editButton.isEnabled = eitherLoaded
        if !eitherLoaded {
            // Ensure edit button resets to gray when no videos loaded
            editButton.tintColor = .systemGray
            editButton.setTitleColor(.systemGray, for: .normal)
        } else if !isEditMode {
            editButton.tintColor = .white
            editButton.setTitleColor(.white, for: .normal)
        }
        
        // Force layout to recalculate the button width after text changes
        closeButtonContainer.setNeedsLayout()
        closeButtonContainer.layoutIfNeeded()
    }

    private func updateStackAxisForOrientation() {
        if view.bounds.width > view.bounds.height {
            // Landscape: side by side
            stackView.axis = .horizontal
        } else {
            // Portrait: top / bottom
            stackView.axis = .vertical
        }
    }

    // MARK: - Player setup

    private func configurePlayers() {
        configureLeftPlayer()
        configureRightPlayer()
        updateLinkButtonState()
    }

    private func configureLeftPlayer() {
        if let url = leftURL {
            leftContainer.showVideo()
            leftContainer.resetPlayState()
            let player = AVPlayer(url: url)
            leftPlayer = player
            leftContainer.playerView.player = player
            addTimeObserver(for: player, isLeft: true)
        } else {
            leftContainer.showAddButton()
        }
    }

    private func configureRightPlayer() {
        if let url = rightURL {
            rightContainer.showVideo()
            rightContainer.resetPlayState()
            let player = AVPlayer(url: url)
            rightPlayer = player
            rightContainer.playerView.player = player
            addTimeObserver(for: player, isLeft: false)
        } else {
            rightContainer.showAddButton()
        }
    }

    private func addTimeObserver(for player: AVPlayer, isLeft: Bool) {
        let interval = CMTime(value: 1, timescale: 60)
        
        let observer = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak player] time in
            guard let self = self, let p = player else { return }
            guard p.currentItem?.status == .readyToPlay else { return }
            
            let current = CMTimeGetSeconds(time)
            var calculatedValue: Float = 0.0 // Renamed to avoid any shadow confusion
            
            if let durationTime = p.currentItem?.duration, CMTIME_IS_NUMERIC(durationTime) {
                let total = CMTimeGetSeconds(durationTime)
                if total > 0 {
                    calculatedValue = Float(current / total)
                }
            }
            
            DispatchQueue.main.async {
                if self.isLinked {
                    if isLeft {
                        // Convert absolute left-video time to relative (seconds from sync point)
                        let relSecs = current - self.linkStartLeft

                        // Update slider
                        if !self.sharedScrubSlider.isTracking && self.linkedWindowDuration > 0 {
                            let sliderVal = Float((relSecs + self.linkedWindowBack) / self.linkedWindowDuration)
                            self.sharedScrubSlider.value = max(0, min(1, sliderVal))
                        }
                        self.sharedTimeLabel.text = self.formatRelativeTime(relSecs)


                    }
                } else {
                    if isLeft {
                        self.leftContainer.updateSlider(value: calculatedValue, currentTime: current, totalTime: 0)
                    } else {
                        self.rightContainer.updateSlider(value: calculatedValue, currentTime: current, totalTime: 0)
                    }
                }
            }
        }
        
        if isLeft {
            leftTimeObserver = observer
        } else {
            rightTimeObserver = observer
        }
    }
    
    private func formatTime(_ secs: Double) -> String {
        guard secs.isFinite && secs >= 0 else { return "00:00.00" }
        let totalSeconds = Int(secs)
        let m = totalSeconds / 60
        let s = totalSeconds % 60
        let fraction = secs.truncatingRemainder(dividingBy: 1.0)
        let hundredths = Int(fraction * 100)
        return String(format: "%02d:%02d.%02d", m, s, hundredths)
    }

    /// Shows time relative to the sync point: "-0:01.50" before, "+0:01.50" after, "0:00.00" at sync
    private func formatRelativeTime(_ secs: Double) -> String {
        guard secs.isFinite else { return "0:00.00" }
        let sign = secs < -0.005 ? "-" : (secs > 0.005 ? "+" : " ")
        let abs = Swift.abs(secs)
        let totalSeconds = Int(abs)
        let m = totalSeconds / 60
        let s = totalSeconds % 60
        let hundredths = Int(abs.truncatingRemainder(dividingBy: 1.0) * 100)
        return String(format: "%@%d:%02d.%02d", sign, m, s, hundredths)
    }

    private func installBoundaryObserver() {
        removeBoundaryObserver()
        guard let leftP = leftPlayer, linkedWindowForward > 0 else { return }
        let endTime = linkStartLeft + linkedWindowForward
        let boundary = CMTime(seconds: endTime, preferredTimescale: 600)
        linkedBoundaryObserver = leftP.addBoundaryTimeObserver(
            forTimes: [NSValue(time: boundary)],
            queue: .main
        ) { [weak self] in
            guard let self, self.isSharedPlaying else { return }
            // Seek both to exact end frame then pause
            let leftEnd  = CMTime(seconds: self.linkStartLeft  + self.linkedWindowForward, preferredTimescale: 600)
            let rightEnd = CMTime(seconds: self.linkStartRight + self.linkedWindowForward, preferredTimescale: 600)
            self.leftPlayer?.seek(to: leftEnd,  toleranceBefore: .zero, toleranceAfter: .zero)
            self.rightPlayer?.seek(to: rightEnd, toleranceBefore: .zero, toleranceAfter: .zero)
            self.leftPlayer?.pause()
            self.rightPlayer?.pause()
            self.isSharedPlaying = false
            self.sharedScrubSlider.value = 1.0
            self.sharedTimeLabel.text = self.formatRelativeTime(self.linkedWindowForward)
            self.updateSharedPlayPauseIcon()
        }
    }

    private func removeBoundaryObserver() {
        if let obs = linkedBoundaryObserver {
            leftPlayer?.removeTimeObserver(obs)
            linkedBoundaryObserver = nil
        }
    }

    private func tearDownPlayers() {
        removeBoundaryObserver()
        if let obs = leftTimeObserver {
            leftPlayer?.removeTimeObserver(obs)
        }
        if let obs = rightTimeObserver {
            rightPlayer?.removeTimeObserver(obs)
        }
        leftTimeObserver = nil
        rightTimeObserver = nil

        leftPlayer?.pause()
        leftPlayer = nil
        rightPlayer?.pause()
        rightPlayer = nil
    }

    // MARK: - Actions

    @objc private func closeTapped() {
        tearDownPlayers()
        dismiss(animated: true) { [weak self] in
            self?.onDismiss?()
        }
    }
    
    @objc private func restartTapped() {
        // Just signal up; do NOT dismiss here.
        onRestartRequested?()
    }

    @objc private func stopSessionTapped() {
        // Just signal up; do NOT dismiss here.
        onStopSessionRequested?()
    }

    @objc private func addLeftTapped() {
        leftContainer.showLoading()
        presentPicker(forLeft: true)
    }

    @objc private func addRightTapped() {
        rightContainer.showLoading()
        presentPicker(forLeft: false)
    }

    private func presentPicker(forLeft: Bool) {
        let picker = UIImagePickerController()
        picker.sourceType = .savedPhotosAlbum // shows recent first
        picker.mediaTypes = [UTType.movie.identifier, UTType.video.identifier]
        picker.delegate = self
        picker.videoExportPreset = AVAssetExportPresetPassthrough
        picker.modalPresentationStyle = .fullScreen
        picker.view.tag = forLeft ? 1 : 2  // use tag to know which side

        present(picker, animated: true)
    }

    @objc private func leftSliderChanged(_ sender: UISlider) {
        guard let player = leftPlayer, let duration = player.currentItem?.duration, CMTIME_IS_NUMERIC(duration) else { return }
        let total = CMTimeGetSeconds(duration)
        let targetSeconds = Double(sender.value) * total
        
        // Update the text instantly while dragging!
        leftContainer.updateSlider(value: sender.value, currentTime: targetSeconds, totalTime: 0)
        
        let time = CMTime(seconds: targetSeconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    @objc private func rightSliderChanged(_ sender: UISlider) {
        guard let player = rightPlayer, let duration = player.currentItem?.duration, CMTIME_IS_NUMERIC(duration) else { return }
        let total = CMTimeGetSeconds(duration)
        let targetSeconds = Double(sender.value) * total
        
        // Update the text instantly while dragging!
        rightContainer.updateSlider(value: sender.value, currentTime: targetSeconds, totalTime: 0)
        
        let time = CMTime(seconds: targetSeconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    @objc private func linkTapped() {
        guard let leftP = leftPlayer, let rightP = rightPlayer else {
            let alert = UIAlertController(title: "Cannot Link", message: "Please load both videos first.", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }

        isLinked.toggle()
        let cfg = UIImage.SymbolConfiguration(pointSize: 28, weight: .regular)

        if isLinked {
            // Linked state
            linkButton.setImage(UIImage(systemName: "link.circle", withConfiguration: cfg), for: .normal)
            linkButton.setTitle(" Unlink", for: .normal)
            linkButton.tintColor = .systemYellow
            linkButton.setTitleColor(.systemYellow, for: .normal)

            // Capture start positions
            let leftT  = CMTimeGetSeconds(leftP.currentTime())
            let rightT = CMTimeGetSeconds(rightP.currentTime())
            syncOffsetSeconds = rightT - leftT
            linkStartLeft  = leftT
            linkStartRight = rightT

            // Determine the valid scrub window around the sync point
            let leftDur  = CMTIME_IS_NUMERIC(leftP.currentItem?.duration ?? .invalid)
                ? CMTimeGetSeconds(leftP.currentItem!.duration) : 0
            let rightDur = CMTIME_IS_NUMERIC(rightP.currentItem?.duration ?? .invalid)
                ? CMTimeGetSeconds(rightP.currentItem!.duration) : 0

            // How far back from the sync point do BOTH videos have content?
            linkedWindowBack    = min(leftT, rightT)
            // How far forward from the sync point do BOTH videos have content?
            linkedWindowForward = min(leftDur - leftT, rightDur - rightT)
            // Safety: ensure at least a minimal window
            if linkedWindowForward <= 0 { linkedWindowForward = 0 }
            if linkedWindowBack    <= 0 { linkedWindowBack    = 0 }

            // Install precise end-of-window boundary observer on left player
            installBoundaryObserver()

            // Pause both
            leftP.pause()
            rightP.pause()
            leftContainer.resetPlayState()
            rightContainer.resetPlayState()
            isSharedPlaying = false
            updateSharedPlayPauseIcon()

            // Swap UI
            leftContainer.controlsContainer.isHidden = true
            rightContainer.controlsContainer.isHidden = true
            sharedControlsContainer.isHidden = false

            // Slider starts at the sync point: back/(back+forward) along the window
            let sliderVal = linkedWindowDuration > 0
                ? Float(linkedWindowBack / linkedWindowDuration) : 0
            sharedScrubSlider.value = sliderVal.isNaN ? 0 : sliderVal
            // Time label shows elapsed time relative to sync point (0.00 = the linked frame)
            sharedTimeLabel.text = "0:00.00"  // at sync point

        } else {
            // Unlinked state
            removeBoundaryObserver()
            linkButton.setImage(UIImage(systemName: "link.circle", withConfiguration: cfg), for: .normal)
            linkButton.setTitle(" Link", for: .normal)
            linkButton.tintColor = .white
            linkButton.setTitleColor(.white, for: .normal)

            // Pause shared
            leftP.pause()
            rightP.pause()
            isSharedPlaying = false
            updateSharedPlayPauseIcon()

            // Swap UI back
            sharedControlsContainer.isHidden = true
            leftContainer.controlsContainer.isHidden = false
            rightContainer.controlsContainer.isHidden = false
        }
    }
    
    @objc private func editTapped() {
        isEditMode.toggle()
        leftContainer.toggleEditMode()
        rightContainer.toggleEditMode()
        let color: UIColor = isEditMode ? .systemYellow : .white
        editButton.tintColor = color
        editButton.setTitleColor(color, for: .normal)
    }

    @objc private func handleRemoveNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let container = userInfo["container"] as? VideoPaneView else { return }

        // If linked, cleanly unlink before tearing down the player
        if isLinked {
            isLinked = false
            removeBoundaryObserver()
            let cfg = UIImage.SymbolConfiguration(pointSize: 28, weight: .regular)
            linkButton.setImage(UIImage(systemName: "link.circle", withConfiguration: cfg), for: .normal)
            linkButton.setTitle(" Link", for: .normal)
            linkButton.tintColor = .white
            linkButton.setTitleColor(.white, for: .normal)
            sharedControlsContainer.isHidden = true
            leftContainer.controlsContainer.isHidden = false
            rightContainer.controlsContainer.isHidden = false
            isSharedPlaying = false
            updateSharedPlayPauseIcon()
        }

        if container === leftContainer {
            leftURL = nil
            leftPlayer?.pause()
            if let obs = leftTimeObserver {
                leftPlayer?.removeTimeObserver(obs)
                leftTimeObserver = nil
            }
            leftPlayer = nil
            leftContainer.clearPlayer()  // ← ADD THIS LINE
            leftContainer.showAddButton()
            
            // Clean up temp file
            if let url = leftURL, url.path.contains("LooprSplitTmp") {
                try? FileManager.default.removeItem(at: url)
            }
            
        } else if container === rightContainer {
            rightURL = nil
            rightPlayer?.pause()
            if let obs = rightTimeObserver {
                rightPlayer?.removeTimeObserver(obs)
                rightTimeObserver = nil
            }
            rightPlayer = nil
            rightContainer.clearPlayer()  // ← ADD THIS LINE
            rightContainer.showAddButton()
            
            // Clean up temp file
            if let url = rightURL, url.path.contains("LooprSplitTmp") {
                try? FileManager.default.removeItem(at: url)
            }
        }
        
        // If in edit mode and neither side has a video left, auto-exit edit mode
        if isEditMode && leftPlayer == nil && rightPlayer == nil {
            isEditMode = false
            leftContainer.toggleEditMode()
            rightContainer.toggleEditMode()
            editButton.tintColor = .white
            editButton.setTitleColor(.white, for: .normal)
        }

        updateLinkButtonState()
    }

    @objc private func sharedPlayPauseTapped() {
        guard let leftP = leftPlayer, let rightP = rightPlayer else { return }

        if isSharedPlaying {
            // Pause both, preserve positions
            leftP.pause()
            rightP.pause()
            isSharedPlaying = false
            updateSharedPlayPauseIcon()
        } else {
            // Check if we are at or past the end of the valid window
            let currentLeft = CMTimeGetSeconds(leftP.currentTime())
            let forwardEnd = linkStartLeft + linkedWindowForward
            let atEnd = currentLeft >= forwardEnd - 0.1

            if atEnd {
                // Restart from the original linked start positions (the coach's sync frame)
                let timeL = CMTime(seconds: linkStartLeft,  preferredTimescale: 600)
                let timeR = CMTime(seconds: linkStartRight, preferredTimescale: 600)
                leftP.seek(to: timeL, toleranceBefore: .zero, toleranceAfter: .zero)
                rightP.seek(to: timeR, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    guard let self else { return }
                    leftP.play()
                    rightP.play()
                    self.isSharedPlaying = true
                    self.updateSharedPlayPauseIcon()
                }
            } else {
                // Resume from current positions
                leftP.play()
                rightP.play()
                isSharedPlaying = true
                updateSharedPlayPauseIcon()
            }
        }
    }

    private func updateSharedPlayPauseIcon() {
        let iconName = isSharedPlaying ? "pause.circle.fill" : "play.circle.fill"
        let cfg = UIImage.SymbolConfiguration(pointSize: 28, weight: .bold)
        sharedPlayPauseButton.setImage(UIImage(systemName: iconName, withConfiguration: cfg), for: .normal)
    }

    @objc private func sharedSliderChanged(_ sender: UISlider) {
        guard let leftP = leftPlayer, let rightP = rightPlayer else { return }
        guard linkedWindowDuration > 0 else { return }

        // Slider 0→1 maps across the full window (back portion then forward portion)
        // 0.0 = furthest back both videos share; 1.0 = furthest forward both videos share
        let relativeSeconds = Double(sender.value) * linkedWindowDuration - linkedWindowBack
        // relativeSeconds < 0 = before sync point, > 0 = after sync point

        let targetLeft  = linkStartLeft  + relativeSeconds
        let targetRight = linkStartRight + relativeSeconds

        // Clamp to each video's actual duration (shouldn't be needed but defensive)
        let leftDur  = CMTIME_IS_NUMERIC(leftP.currentItem?.duration  ?? .invalid)
            ? CMTimeGetSeconds(leftP.currentItem!.duration)  : 0
        let rightDur = CMTIME_IS_NUMERIC(rightP.currentItem?.duration ?? .invalid)
            ? CMTimeGetSeconds(rightP.currentItem!.duration) : 0
        let safeLeft  = max(0, min(targetLeft,  leftDur))
        let safeRight = max(0, min(targetRight, rightDur))

        // Label shows time relative to sync point (negative = before, positive = after)
        sharedTimeLabel.text = formatRelativeTime(relativeSeconds)

        leftP.seek(to:  CMTime(seconds: safeLeft,  preferredTimescale: 600),
                   toleranceBefore: .zero, toleranceAfter: .zero)
        rightP.seek(to: CMTime(seconds: safeRight, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }
}

// MARK: - UIGestureRecognizerDelegate

extension SplitVideoView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        // Ignore taps on any UIControl (buttons, sliders) or their container views
        let excludedViews: [UIView] = [
            closeButtonContainer,
            topRightContainer,
            sharedControlsContainer,
            leftContainer.controlsContainer,
            rightContainer.controlsContainer,
            leftContainer.addButton,
            rightContainer.addButton,
            leftContainer.removeButton,
            rightContainer.removeButton
        ]
        for excluded in excludedViews {
            if touch.view?.isDescendant(of: excluded) == true {
                return false
            }
        }
        return true
    }
}

// MARK: - Picker delegate

extension SplitVideoView: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        if picker.view.tag == 1 {
            leftContainer.hideLoading()
        } else {
            rightContainer.hideLoading()
        }
        dismiss(animated: true)
    }

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
        defer {
            if picker.view.tag == 1 {
                leftContainer.hideLoading()
            } else {
                rightContainer.hideLoading()
            }
            picker.dismiss(animated: true)
        }
        guard let url = info[.mediaURL] as? URL else { return }

        let forLeft = (picker.view.tag == 1)

        if isLinked {
            linkTapped()
        }
        
        if forLeft {
            leftURL = url
            leftPlayer?.pause()
            leftPlayer = AVPlayer(url: url)
            leftContainer.showVideo()
            leftContainer.resetPlayState()
            leftContainer.playerView.player = leftPlayer
            if let obs = leftTimeObserver {
                leftPlayer?.removeTimeObserver(obs)
                leftTimeObserver = nil
            }
            if let player = leftPlayer {
                addTimeObserver(for: player, isLeft: true)
            }
        } else {
            rightURL = url
            rightPlayer?.pause()
            rightPlayer = AVPlayer(url: url)
            rightContainer.showVideo()
            rightContainer.resetPlayState()
            rightContainer.playerView.player = rightPlayer
            if let obs = rightTimeObserver {
                rightPlayer?.removeTimeObserver(obs)
                rightTimeObserver = nil
            }
            if let player = rightPlayer {
                addTimeObserver(for: player, isLeft: false)
            }
        }
        
        updateLinkButtonState()
    }
    
    @objc private func removeVideoForContainer(_ container: VideoPaneView) {
        if container === leftContainer {
            leftURL = nil
            leftPlayer?.pause()
            leftPlayer = nil
            leftContainer.showAddButton()
            leftContainer.resetPlayState()
            
            // Clean up temp file if it was one of our clips
            if let url = leftURL, url.path.contains("LooprSplitTmp") {
                try? FileManager.default.removeItem(at: url)
            }
            
        } else if container === rightContainer {
            rightURL = nil
            rightPlayer?.pause()
            rightPlayer = nil
            rightContainer.showAddButton()
            rightContainer.resetPlayState()
            
            // Clean up temp file if it was one of our clips
            if let url = rightURL, url.path.contains("LooprSplitTmp") {
                try? FileManager.default.removeItem(at: url)
            }
        }
        
        // Update link button state and unlink if necessary
        updateLinkButtonState()
    }

}

// MARK: - VideoPaneView (subview for each side)
private final class VideoPaneView: UIView {
    let playerView = PlayerContainerView()
    let addButton = UIButton(type: .system)
    let removeButton = UIButton(type: .system)

    // Controls matching RecordedVideoView
    let controlsContainer = UIView()
    let playPauseButton = UIButton(type: .system)
    let scrubSlider = UISlider()
    let timeLabel = UILabel()
    let loadingSpinner = UIActivityIndicatorView(style: .large)
    
    private var isPlaying = false
    var isInEditMode = false

    // Zoom / pan state
    private let zoomContainer = UIView()  // receives transform; playerView lives inside
    private var currentScale: CGFloat = 1.0
    private var currentTranslation: CGPoint = .zero

    init() {
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup() {
        backgroundColor = .black
        clipsToBounds = true  // prevent zoomed video from bleeding into the other pane

        playerView.translatesAutoresizingMaskIntoConstraints = false

        addButton.setTitle("Add Video", for: .normal)
        addButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        addButton.setTitleColor(.white, for: .normal)
        // Changed to match the scrubber purple color from RecordedVideoView
        addButton.backgroundColor = UIColor(red: 96/255, green: 73/255, blue: 157/255, alpha: 1)
        // Reduced from 16 to 12 for less rounded look
        addButton.layer.cornerRadius = 12
        addButton.clipsToBounds = true
        addButton.translatesAutoresizingMaskIntoConstraints = false
        
        removeButton.setTitle("Remove", for: .normal)
        removeButton.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        removeButton.setTitleColor(.white, for: .normal)
        removeButton.backgroundColor = UIColor(red: 96/255, green: 73/255, blue: 157/255, alpha: 1) // Purple
        removeButton.layer.cornerRadius = 12
        removeButton.clipsToBounds = true
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.isHidden = true // Hidden by default
        removeButton.addTarget(self, action: #selector(removeVideoTapped), for: .touchUpInside)

        // Loading spinner
        loadingSpinner.color = .white
        loadingSpinner.hidesWhenStopped = true
        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        loadingSpinner.isHidden = true
        
        // Container matches RecordedVideoView (black with 0.7 alpha)
        controlsContainer.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        controlsContainer.layer.cornerRadius = 24
        controlsContainer.translatesAutoresizingMaskIntoConstraints = false

        // Play/Pause button
        let cfg = UIImage.SymbolConfiguration(pointSize: 28, weight: .bold)
        playPauseButton.setImage(UIImage(systemName: "play.circle.fill", withConfiguration: cfg), for: .normal)
        playPauseButton.tintColor = .white
        playPauseButton.translatesAutoresizingMaskIntoConstraints = false
        playPauseButton.addTarget(self, action: #selector(togglePlayPause), for: .touchUpInside)

        // Scrubber
        // Custom yellow-bordered white thumb
        // 20x20 thumb - stroke fits PERFECTLY inside slider bounds
        let thumbSize: CGFloat = 20
        let strokeWidth: CGFloat = 1.5  // Thinner stroke
        let padding: CGFloat = 1.5      // Extra safety margin

        let thumbImage = UIGraphicsImageRenderer(size: CGSize(width: thumbSize, height: thumbSize))
            .image { context in
                // White fill (smaller circle)
                let fillSize = thumbSize - (strokeWidth * 2) - (padding * 2)
                let fillRect = CGRect(x: padding + strokeWidth, y: padding + strokeWidth,
                                     width: fillSize, height: fillSize)
                UIColor.white.setFill()
                UIBezierPath(ovalIn: fillRect).fill()
                
                // Yellow stroke (slightly inset)
                let strokeRect = CGRect(x: padding, y: padding,
                                       width: thumbSize - (padding * 2),
                                       height: thumbSize - (padding * 2))
                UIColor.systemYellow.setStroke()
                let strokePath = UIBezierPath(ovalIn: strokeRect)
                strokePath.lineWidth = strokeWidth
                strokePath.lineCapStyle = .round
                strokePath.lineJoinStyle = .round
                strokePath.stroke()
            }

        scrubSlider.setThumbImage(thumbImage.withRenderingMode(.alwaysOriginal), for: .normal)

        scrubSlider.minimumTrackTintColor = .white
        scrubSlider.maximumTrackTintColor = UIColor(red: 96/255, green: 73/255, blue: 157/255, alpha: 1)
        scrubSlider.translatesAutoresizingMaskIntoConstraints = false

        // Time Label
        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        timeLabel.textColor = .white
        timeLabel.text = "00:00.00"
        timeLabel.textAlignment = .right
        timeLabel.translatesAutoresizingMaskIntoConstraints = false

        // zoomContainer clips to its bounds so zoomed video stays within pane
        zoomContainer.clipsToBounds = true
        zoomContainer.translatesAutoresizingMaskIntoConstraints = false
        zoomContainer.addSubview(playerView)
        addSubview(zoomContainer)
        addSubview(addButton)
        addSubview(removeButton)
        addSubview(loadingSpinner)
        addSubview(controlsContainer)
        
        controlsContainer.addSubview(playPauseButton)
        controlsContainer.addSubview(scrubSlider)
        controlsContainer.addSubview(timeLabel)

        NSLayoutConstraint.activate([
            // zoomContainer fills the player area
            zoomContainer.topAnchor.constraint(equalTo: topAnchor),
            zoomContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            zoomContainer.trailingAnchor.constraint(equalTo: trailingAnchor),

            // playerView fills zoomContainer — transform is applied to zoomContainer
            playerView.topAnchor.constraint(equalTo: zoomContainer.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: zoomContainer.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: zoomContainer.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: zoomContainer.bottomAnchor),

            // Give player the most space, keep controls at the bottom
            controlsContainer.topAnchor.constraint(equalTo: zoomContainer.bottomAnchor, constant: 8),
            controlsContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            controlsContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            controlsContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            controlsContainer.heightAnchor.constraint(equalToConstant: 48),

            addButton.centerXAnchor.constraint(equalTo: playerView.centerXAnchor),
            addButton.centerYAnchor.constraint(equalTo: playerView.centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 140),
            addButton.heightAnchor.constraint(equalToConstant: 44),
            
            removeButton.centerXAnchor.constraint(equalTo: playerView.centerXAnchor),
            removeButton.centerYAnchor.constraint(equalTo: playerView.centerYAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: 140),
            removeButton.heightAnchor.constraint(equalToConstant: 44),
            
            loadingSpinner.centerXAnchor.constraint(equalTo: playerView.centerXAnchor),
            loadingSpinner.centerYAnchor.constraint(equalTo: playerView.centerYAnchor),

            // Controls inside container
            playPauseButton.leadingAnchor.constraint(equalTo: controlsContainer.leadingAnchor, constant: 8),
            playPauseButton.centerYAnchor.constraint(equalTo: controlsContainer.centerYAnchor),
            playPauseButton.widthAnchor.constraint(equalToConstant: 32),
            playPauseButton.heightAnchor.constraint(equalToConstant: 32),

            timeLabel.trailingAnchor.constraint(equalTo: controlsContainer.trailingAnchor, constant: -12),
            timeLabel.centerYAnchor.constraint(equalTo: controlsContainer.centerYAnchor),
            timeLabel.widthAnchor.constraint(equalToConstant: 72),

            scrubSlider.leadingAnchor.constraint(equalTo: playPauseButton.trailingAnchor, constant: 10),
            scrubSlider.trailingAnchor.constraint(equalTo: timeLabel.leadingAnchor, constant: -10),
            scrubSlider.centerYAnchor.constraint(equalTo: controlsContainer.centerYAnchor)
        ])
    }

    func setupZoomGestures() {
        // Only install once — remove any existing gesture recognizers first
        zoomContainer.gestureRecognizers?.forEach { zoomContainer.removeGestureRecognizer($0) }

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        let pan   = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(resetZoom))
        doubleTap.numberOfTapsRequired = 2

        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 2
        pinch.delegate = self
        pan.delegate   = self

        zoomContainer.addGestureRecognizer(pinch)
        zoomContainer.addGestureRecognizer(pan)
        zoomContainer.addGestureRecognizer(doubleTap)
        zoomContainer.isUserInteractionEnabled = true
    }

    @objc func resetZoom() {
        currentScale = 1.0
        currentTranslation = .zero
        UIView.animate(withDuration: 0.3) {
            self.zoomContainer.transform = .identity
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .changed, .ended:
            let newScale = max(1.0, min(currentScale * gesture.scale, 6.0))
            currentScale = newScale
            gesture.scale = 1.0
            applyTransform()
        default:
            break
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard currentScale > 1.0 else { return }  // no drag when not zoomed
        let delta = gesture.translation(in: self)
        currentTranslation.x += delta.x
        currentTranslation.y += delta.y
        gesture.setTranslation(.zero, in: self)
        clampTranslation()
        applyTransform()
    }

    private func applyTransform() {
        zoomContainer.transform = CGAffineTransform(scaleX: currentScale, y: currentScale)
            .translatedBy(x: currentTranslation.x / currentScale,
                          y: currentTranslation.y / currentScale)
    }

    private func clampTranslation() {
        let w = bounds.width
        let h = bounds.height
        let maxX = (w * (currentScale - 1)) / 2
        let maxY = (h * (currentScale - 1)) / 2
        currentTranslation.x = max(-maxX, min(currentTranslation.x, maxX))
        currentTranslation.y = max(-maxY, min(currentTranslation.y, maxY))
    }

    @objc private func togglePlayPause() {
        guard let player = playerView.player else { return }

        if player.rate > 0 {
            // Currently playing → pause
            player.pause()
            isPlaying = false
            updatePlayPauseIcon()
        } else {
            // Check if at or near the end
            let duration = player.currentItem?.duration ?? .zero
            let current = player.currentTime()
            let atEnd = CMTIME_IS_NUMERIC(duration) && CMTIME_IS_NUMERIC(current)
                && CMTimeGetSeconds(current) >= CMTimeGetSeconds(duration) - 0.1

            if atEnd {
                // At end → restart from beginning
                player.seek(to: .zero) { _ in
                    player.play()
                    self.isPlaying = true
                    self.updatePlayPauseIcon()
                }
            } else {
                // Paused mid-video → resume from current position
                player.play()
                isPlaying = true
                updatePlayPauseIcon()
            }
        }
    }
    
    func toggleEditMode() {
        isInEditMode.toggle()
        
        if isInEditMode {
            if playerView.player != nil {
                showRemoveButton()
            } else {
                showAddButton()
            }
        } else {
            if playerView.player != nil {
                showVideo()
            } else {
                showAddButton()
            }
        }
    }
    
    func clearPlayer() {
        playerView.player = nil
        resetPlayState()
        resetZoom()
    }

    func resetPlayState() {
        isPlaying = false
        updatePlayPauseIcon()
        scrubSlider.value = 0
        timeLabel.text = "00:00.00"
    }

    private func updatePlayPauseIcon() {
        let iconName = isPlaying ? "pause.circle.fill" : "play.circle.fill"
        let cfg = UIImage.SymbolConfiguration(pointSize: 28, weight: .bold)
        playPauseButton.setImage(UIImage(systemName: iconName, withConfiguration: cfg), for: .normal)
    }

    func showVideo() {
        addButton.isHidden = true
        removeButton.isHidden = true
        controlsContainer.isHidden = false
        playerView.isHidden = false
        setupZoomGestures()
    }

    func showAddButton() {
        addButton.isHidden = false
        removeButton.isHidden = true
        controlsContainer.isHidden = true
        playerView.isHidden = false
    }

    func showRemoveButton() {
        addButton.isHidden = true
        removeButton.isHidden = false
        controlsContainer.isHidden = true
    }
    
    func showLoading() {
        addButton.isHidden = true
        loadingSpinner.startAnimating()
        loadingSpinner.isHidden = false
    }

    func hideLoading() {
        loadingSpinner.stopAnimating()
        loadingSpinner.isHidden = true
        // Restore appropriate state
        if playerView.player == nil {
            showAddButton()
        }
    }
    
    @objc private func removeVideoTapped() {
        // Post a notification that SplitVideoView can listen for
        let notificationName = Notification.Name("VideoPaneViewRemoveTapped")
        let userInfo: [String: VideoPaneView] = ["container": self]
        NotificationCenter.default.post(name: notificationName, object: nil, userInfo: userInfo)
    }

    func updateSlider(value: Float, currentTime: Double, totalTime: Double) {
        // ALWAYS update the text
        timeLabel.text = formatTime(currentTime)
        
        // Only override the physical slider position if the user IS NOT actively dragging it
        if !scrubSlider.isTracking {
            scrubSlider.value = value
        }
        
        // Auto-pause UI at the end of the video
        if value >= 0.99 && isPlaying {
            isPlaying = false
            updatePlayPauseIcon()
        }
    }

    private func formatTime(_ secs: Double) -> String {
        guard secs.isFinite && secs >= 0 else { return "00:00.00" }
        let totalSeconds = Int(secs)
        let m = totalSeconds / 60
        let s = totalSeconds % 60
        let fraction = secs.truncatingRemainder(dividingBy: 1.0)
        let hundredths = Int(fraction * 100)
        return String(format: "%02d:%02d.%02d", m, s, hundredths)
    }
}

extension VideoPaneView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gr: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        return true  // allow pinch + pan at the same time
    }
}

// Simple view whose backing layer is AVPlayerLayer
private final class PlayerContainerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        return layer as! AVPlayerLayer
    }

    var player: AVPlayer? {
        get { playerLayer.player }
        set {
            playerLayer.videoGravity = .resizeAspect
            playerLayer.player = newValue
        }
    }
}
