import UIKit
import AVFoundation
import Photos
import UniformTypeIdentifiers

final class SplitVideoView: UIViewController {

    // MARK: - Public API

    var leftURL: URL?
    var rightURL: URL?

    var onDismiss: (() -> Void)?
    var onRestartRequested: (() -> Void)?
    var onStopSessionRequested: (() -> Void)?

    // MARK: - Private AV state

    private var leftPlayer: AVPlayer?
    private var rightPlayer: AVPlayer?

    private var leftTimeObserver: Any?
    private var rightTimeObserver: Any?
    private var linkedBoundaryObserver: Any?

    private var isLinked: Bool = false
    private var isEditMode: Bool = false
    private var controlsVisible: Bool = true
    private var isSharedPlaying: Bool = false
    private var syncOffsetSeconds: Double = 0.0
    private var linkStartLeft:  Double = 0.0
    private var linkStartRight: Double = 0.0
    private var linkedWindowBack:    Double = 0.0
    private var linkedWindowForward: Double = 0.0
    private var linkedWindowDuration: Double { linkedWindowBack + linkedWindowForward }
    
    private var sharedTrackedLeftSeconds: Double = 0.0

    // MARK: - UI Components

    private let closeButtonContainer: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        v.layer.cornerRadius = 32
        v.translatesAutoresizingMaskIntoConstraints = false
        v.clipsToBounds = true
        return v
    }()

    private let closeButton: UIButton = {
        let b = UIButton(type: .system)
        let cfg = UIImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        b.setImage(UIImage(systemName: "chevron.backward.circle", withConfiguration: cfg), for: .normal)
        b.tintColor = .white
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let linkButton: UIButton = {
        let b = UIButton(type: .system)
        let cfg = UIImage.SymbolConfiguration(pointSize: 28, weight: .regular)
        b.setImage(UIImage(systemName: "link.circle", withConfiguration: cfg), for: .normal)
        b.setTitle(" Link", for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        b.tintColor = .systemGray
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
        b.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
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
        let cfg = UIImage.SymbolConfiguration(pointSize: 32, weight: .bold)
        b.setImage(UIImage(systemName: "arrow.clockwise.circle.fill", withConfiguration: cfg), for: .normal)
        b.tintColor = .systemGreen
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let stopSessionButton: UIButton = {
        let b = UIButton(type: .system)
        let cfg = UIImage.SymbolConfiguration(pointSize: 32, weight: .bold)
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

    private let sharedControlsContainer: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        v.layer.cornerRadius = 24
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true
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
        let thumbSize: CGFloat = 20
        let strokeWidth: CGFloat = 1.5
        let padding: CGFloat = 1.5

        let thumbImage = UIGraphicsImageRenderer(size: CGSize(width: thumbSize, height: thumbSize))
            .image { context in
                let fillSize = thumbSize - (strokeWidth * 2) - (padding * 2)
                let fillRect = CGRect(x: padding + strokeWidth, y: padding + strokeWidth, width: fillSize, height: fillSize)
                UIColor.white.setFill()
                UIBezierPath(ovalIn: fillRect).fill()
                
                let strokeRect = CGRect(x: padding, y: padding, width: thumbSize - (padding * 2), height: thumbSize - (padding * 2))
                UIColor.systemYellow.setStroke()
                let strokePath = UIBezierPath(ovalIn: strokeRect)
                strokePath.lineWidth = strokeWidth
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
        l.text = "0:00.00"
        l.textAlignment = .right
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let sharedFrameDial: FrameDial = {
        let dial = FrameDial()
        dial.translatesAutoresizingMaskIntoConstraints = false
        return dial
    }()

    // MARK: - Lifecycle

    init(leftURL: URL?, rightURL: URL?) {
        self.leftURL = leftURL
        self.rightURL = rightURL
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupUI()
        setupActions()
        setupTapGesture()
        configurePlayers()
        
        NotificationCenter.default.addObserver(self, selector: #selector(handleRemoveNotification(_:)), name: Notification.Name("VideoPaneViewRemoveTapped"), object: nil)
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

        view.addSubview(sharedControlsContainer)
        sharedControlsContainer.addSubview(sharedPlayPauseButton)
        sharedControlsContainer.addSubview(sharedScrubSlider)
        sharedControlsContainer.addSubview(sharedTimeLabel)
        sharedControlsContainer.addSubview(sharedFrameDial)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            closeButtonContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            closeButtonContainer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            closeButtonContainer.heightAnchor.constraint(equalToConstant: 64),

            closeButton.leadingAnchor.constraint(equalTo: closeButtonContainer.leadingAnchor, constant: 10),
            closeButton.centerYAnchor.constraint(equalTo: closeButtonContainer.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 44),

            editButton.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 4),
            editButton.centerYAnchor.constraint(equalTo: closeButtonContainer.centerYAnchor),

            linkButton.leadingAnchor.constraint(equalTo: editButton.trailingAnchor, constant: 12),
            linkButton.centerYAnchor.constraint(equalTo: closeButtonContainer.centerYAnchor),
            linkButton.trailingAnchor.constraint(equalTo: closeButtonContainer.trailingAnchor, constant: -16),

            topRightContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            topRightContainer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            topRightContainer.heightAnchor.constraint(equalToConstant: 64),
            topRightContainer.widthAnchor.constraint(equalToConstant: 120),

            restartButton.leadingAnchor.constraint(equalTo: topRightContainer.leadingAnchor, constant: 12),
            restartButton.centerYAnchor.constraint(equalTo: topRightContainer.centerYAnchor),
            stopSessionButton.trailingAnchor.constraint(equalTo: topRightContainer.trailingAnchor, constant: -12),
            stopSessionButton.centerYAnchor.constraint(equalTo: topRightContainer.centerYAnchor),

            sharedControlsContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            sharedControlsContainer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            sharedControlsContainer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            sharedControlsContainer.heightAnchor.constraint(equalToConstant: 82),

            sharedPlayPauseButton.leadingAnchor.constraint(equalTo: sharedControlsContainer.leadingAnchor, constant: 8),
            sharedPlayPauseButton.topAnchor.constraint(equalTo: sharedControlsContainer.topAnchor, constant: 6),
            sharedPlayPauseButton.widthAnchor.constraint(equalToConstant: 32),
            sharedPlayPauseButton.heightAnchor.constraint(equalToConstant: 32),

            sharedTimeLabel.trailingAnchor.constraint(equalTo: sharedControlsContainer.trailingAnchor, constant: -12),
            sharedTimeLabel.centerYAnchor.constraint(equalTo: sharedPlayPauseButton.centerYAnchor),
            sharedTimeLabel.widthAnchor.constraint(equalToConstant: 72),

            sharedScrubSlider.leadingAnchor.constraint(equalTo: sharedPlayPauseButton.trailingAnchor, constant: 10),
            sharedScrubSlider.trailingAnchor.constraint(equalTo: sharedTimeLabel.leadingAnchor, constant: -10),
            sharedScrubSlider.centerYAnchor.constraint(equalTo: sharedPlayPauseButton.centerYAnchor),

            sharedFrameDial.centerXAnchor.constraint(equalTo: sharedScrubSlider.centerXAnchor),
            sharedFrameDial.widthAnchor.constraint(equalTo: sharedScrubSlider.widthAnchor, multiplier: 0.75),
            sharedFrameDial.topAnchor.constraint(equalTo: sharedPlayPauseButton.bottomAnchor, constant: 4),
            sharedFrameDial.heightAnchor.constraint(equalToConstant: 28)
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

        sharedFrameDial.onDragBegan = { [weak self] in
            guard let self = self, let leftP = self.leftPlayer else { return }
            self.sharedTrackedLeftSeconds = CMTimeGetSeconds(leftP.currentTime())
        }
        sharedFrameDial.onFrameStep = { [weak self] delta in
            self?.stepLinkedFrame(delta: delta)
        }
    }
    
    // MARK: - Core Logic

    private func removeLeftObservers() {
        // Remove the periodic time observer from the current leftPlayer
        if let obs = leftTimeObserver {
            leftPlayer?.removeTimeObserver(obs)
            leftTimeObserver = nil
        }
        // Also remove the boundary observer from the current leftPlayer
        removeBoundaryObserver()
    }

    private func removeRightObservers() {
        if let obs = rightTimeObserver {
            rightPlayer?.removeTimeObserver(obs)
            rightTimeObserver = nil
        }
    }
    
    private func configurePlayers() {
        configureLeftPlayer()
        configureRightPlayer()
        updateLinkButtonState()
    }

    private func configureLeftPlayer() {
        // CLEANUP FIRST: Remove observers from the existing instance before replacing it
        removeLeftObservers()
        leftPlayer?.pause()
        leftPlayer = nil

        if let url = leftURL {
            leftContainer.showVideo()
            leftContainer.resetPlayState()
            let player = AVPlayer(url: url)
            leftPlayer = player
            leftContainer.playerView.player = player
            addTimeObserver(for: player, isLeft: true)
            setupDial(for: leftContainer, player: player)
        } else {
            leftContainer.showAddButton()
        }
    }

    private func configureRightPlayer() {
        // CLEANUP FIRST
        removeRightObservers()
        rightPlayer?.pause()
        rightPlayer = nil

        if let url = rightURL {
            rightContainer.showVideo()
            rightContainer.resetPlayState()
            let player = AVPlayer(url: url)
            rightPlayer = player
            rightContainer.playerView.player = player
            addTimeObserver(for: player, isLeft: false)
            setupDial(for: rightContainer, player: player)
        } else {
            rightContainer.showAddButton()
        }
    }

    private func setupDial(for container: VideoPaneView, player: AVPlayer) {
        player.currentItem?.asset.loadValuesAsynchronously(forKeys: ["duration"]) { [weak self, weak player, weak container] in
            guard let self, let player, let container else { return }
            DispatchQueue.main.async {
                guard let item = player.currentItem else { return }
                
                let dur = item.asset.duration
                guard CMTIME_IS_NUMERIC(dur) else { return }
                
                let fps = 30.0
                let total = max(1, Int(CMTimeGetSeconds(dur) * fps))
                container.frameDial.totalFrames = total
                container.frameDial.currentFrame = Int(CMTimeGetSeconds(player.currentTime()) * fps)

                var trackedSeconds = CMTimeGetSeconds(player.currentTime())

                container.frameDial.onDragBegan = { [weak self, weak player] in
                    let current = CMTimeGetSeconds(player?.currentTime() ?? .zero)
                    trackedSeconds = current
                    self?.sharedTrackedLeftSeconds = current
                }

                container.frameDial.onFrameStep = { [weak self, weak player, weak container] delta in
                    guard let self, let player, let container else { return }
                    if self.isLinked {
                        self.stepLinkedFrame(delta: delta)
                    } else {
                        let newTime = max(0, trackedSeconds + Double(delta) / fps)
                        trackedSeconds = newTime
                        let cmt = CMTime(seconds: newTime, preferredTimescale: 600)
                        player.seek(to: cmt, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                            container.frameDial.currentFrame = Int(newTime * fps)
                        }
                        if let dur = player.currentItem?.duration, CMTIME_IS_NUMERIC(dur) {
                            let total = CMTimeGetSeconds(dur)
                            if total > 0 { container.scrubSlider.value = Float(newTime / total) }
                        }
                    }
                }
            }
        }
    }

    private func stepLinkedFrame(delta: Int) {
        guard let leftP = leftPlayer, let rightP = rightPlayer else { return }
        let fps = 30.0
        
        sharedTrackedLeftSeconds += Double(delta) / fps
        let newLeft = sharedTrackedLeftSeconds
        let newRight = newLeft + syncOffsetSeconds

        let clampedLeft  = max(linkStartLeft - linkedWindowBack, min(newLeft, linkStartLeft + linkedWindowForward))
        let rightDur = CMTIME_IS_NUMERIC(rightP.currentItem?.duration ?? .invalid) ? CMTimeGetSeconds(rightP.currentItem!.duration) : 0
        let clampedRight = max(0, min(newRight, rightDur))

        leftP.seek(to: CMTime(seconds: clampedLeft, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        rightP.seek(to: CMTime(seconds: clampedRight, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)

        let relSecs = clampedLeft - linkStartLeft
        leftContainer.frameDial.currentFrame  = Int(clampedLeft * fps)
        rightContainer.frameDial.currentFrame = Int(clampedRight * fps)
        sharedFrameDial.currentFrame = Int((relSecs + linkedWindowBack) * fps)

        if linkedWindowDuration > 0 {
            let sliderVal = Float((relSecs + linkedWindowBack) / linkedWindowDuration)
            sharedScrubSlider.value = max(0, min(1, sliderVal))
            sharedTimeLabel.text = formatRelativeTime(relSecs)
        }
    }

    private func addTimeObserver(for player: AVPlayer, isLeft: Bool) {
        let interval = CMTime(value: 1, timescale: 60)
        let observer = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self, weak player] time in
            guard let self = self, let p = player else { return }
            guard p.currentItem?.status == .readyToPlay else { return }
            
            let current = CMTimeGetSeconds(time)
            var progress: Float = 0.0
            if let dur = p.currentItem?.duration, CMTIME_IS_NUMERIC(dur), CMTimeGetSeconds(dur) > 0 {
                progress = Float(current / CMTimeGetSeconds(dur))
            }
            
            DispatchQueue.main.async {
                if self.isLinked {
                    if isLeft {
                        let relSecs = current - self.linkStartLeft
                        if !self.sharedScrubSlider.isTracking && self.linkedWindowDuration > 0 {
                            let sliderVal = Float((relSecs + self.linkedWindowBack) / self.linkedWindowDuration)
                            self.sharedScrubSlider.value = max(0, min(1, sliderVal))
                            self.sharedFrameDial.currentFrame = Int((relSecs + self.linkedWindowBack) * 30.0)
                        }
                        self.sharedTimeLabel.text = self.formatRelativeTime(relSecs)
                    }
                } else {
                    let container = isLeft ? self.leftContainer : self.rightContainer
                    container.updateSlider(value: progress, currentTime: current, totalTime: 0)
                    container.frameDial.currentFrame = Int(current * 30)
                }
            }
        }
        if isLeft { leftTimeObserver = observer } else { rightTimeObserver = observer }
    }

    @objc private func linkTapped() {
        guard let leftP = leftPlayer, let rightP = rightPlayer else { return }
        isLinked.toggle()
        
        if isLinked {
            linkButton.setTitle(" Unlink", for: .normal)
            linkButton.tintColor = .systemYellow
            linkStartLeft = CMTimeGetSeconds(leftP.currentTime())
            linkStartRight = CMTimeGetSeconds(rightP.currentTime())
            syncOffsetSeconds = linkStartRight - linkStartLeft

            let leftDur = CMTIME_IS_NUMERIC(leftP.currentItem?.duration ?? .invalid) ? CMTimeGetSeconds(leftP.currentItem!.duration) : 0
            let rightDur = CMTIME_IS_NUMERIC(rightP.currentItem?.duration ?? .invalid) ? CMTimeGetSeconds(rightP.currentItem!.duration) : 0
            linkedWindowBack = min(linkStartLeft, linkStartRight)
            linkedWindowForward = min(leftDur - linkStartLeft, rightDur - linkStartRight)

            installBoundaryObserver()
            leftP.pause(); rightP.pause(); isSharedPlaying = false
            updateSharedPlayPauseIcon()
            leftContainer.controlsContainer.isHidden = true
            rightContainer.controlsContainer.isHidden = true
            sharedControlsContainer.isHidden = false

            sharedFrameDial.totalFrames = max(1, Int(linkedWindowDuration * 30.0))
            sharedFrameDial.currentFrame = Int(linkedWindowBack * 30.0)
            sharedScrubSlider.value = linkedWindowDuration > 0 ? Float(linkedWindowBack / linkedWindowDuration) : 0
            sharedTimeLabel.text = "0:00.00"
        } else {
            removeBoundaryObserver()
            linkButton.setTitle(" Link", for: .normal)
            linkButton.tintColor = .white
            sharedControlsContainer.isHidden = true
            leftContainer.controlsContainer.isHidden = false
            rightContainer.controlsContainer.isHidden = false
        }
    }

    @objc private func sharedSliderChanged(_ sender: UISlider) {
        guard let leftP = leftPlayer, let rightP = rightPlayer, linkedWindowDuration > 0 else { return }
        let relSecs = Double(sender.value) * linkedWindowDuration - linkedWindowBack
        let safeLeft = linkStartLeft + relSecs
        let safeRight = linkStartRight + relSecs

        sharedTimeLabel.text = formatRelativeTime(relSecs)
        sharedFrameDial.currentFrame = Int((relSecs + linkedWindowBack) * 30.0)
        
        leftP.seek(to: CMTime(seconds: safeLeft, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        rightP.seek(to: CMTime(seconds: safeRight, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    @objc private func sharedPlayPauseTapped() {
        guard let lp = leftPlayer, let rp = rightPlayer else { return }
        if isSharedPlaying { lp.pause(); rp.pause() } else { lp.play(); rp.play() }
        isSharedPlaying.toggle(); updateSharedPlayPauseIcon()
    }

    private func updateSharedPlayPauseIcon() {
        let icon = isSharedPlaying ? "pause.circle.fill" : "play.circle.fill"
        let cfg = UIImage.SymbolConfiguration(pointSize: 28, weight: .bold)
        sharedPlayPauseButton.setImage(UIImage(systemName: icon, withConfiguration: cfg), for: .normal)
    }

    private func formatRelativeTime(_ secs: Double) -> String {
        let sign = secs < -0.005 ? "-" : (secs > 0.005 ? "+" : " ")
        let absVal = Swift.abs(secs)
        let m = Int(absVal) / 60, s = Int(absVal) % 60, h = Int(absVal.truncatingRemainder(dividingBy: 1.0) * 100)
        return String(format: "%@%d:%02d.%02d", sign, m, s, h)
    }

    private func installBoundaryObserver() {
        removeBoundaryObserver()
        guard let leftP = leftPlayer, linkedWindowForward > 0 else { return }
        let boundary = CMTime(seconds: linkStartLeft + linkedWindowForward, preferredTimescale: 600)
        linkedBoundaryObserver = leftP.addBoundaryTimeObserver(forTimes: [NSValue(time: boundary)], queue: .main) { [weak self] in
            guard let self = self else { return }
            self.leftPlayer?.pause(); self.rightPlayer?.pause(); self.isSharedPlaying = false
            self.updateSharedPlayPauseIcon()
        }
    }

    private func removeBoundaryObserver() {
        if let obs = linkedBoundaryObserver { leftPlayer?.removeTimeObserver(obs) }
        linkedBoundaryObserver = nil
    }

    private func tearDownPlayers() {
        removeLeftObservers()
        removeRightObservers()

        leftPlayer?.pause()
        leftPlayer = nil
        rightPlayer?.pause()
        rightPlayer = nil
    }

    @objc private func closeTapped() { tearDownPlayers(); dismiss(animated: true) { self.onDismiss?() } }
    @objc private func restartTapped() { onRestartRequested?() }
    @objc private func stopSessionTapped() { onStopSessionRequested?() }
    @objc private func addLeftTapped() { leftContainer.showLoading(); presentPicker(forLeft: true) }
    @objc private func addRightTapped() { rightContainer.showLoading(); presentPicker(forLeft: false) }
    
    private func presentPicker(forLeft: Bool) {
        let picker = UIImagePickerController()
        picker.sourceType = .savedPhotosAlbum; picker.mediaTypes = [UTType.movie.identifier]
        picker.delegate = self
        picker.view.tag = forLeft ? 1 : 2
        present(picker, animated: true)
    }

    @objc private func leftSliderChanged(_ sender: UISlider) {
        guard let p = leftPlayer, let dur = p.currentItem?.duration, CMTIME_IS_NUMERIC(dur) else { return }
        let target = Double(sender.value) * CMTimeGetSeconds(dur)
        leftContainer.updateSlider(value: sender.value, currentTime: target, totalTime: 0)
        p.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    @objc private func rightSliderChanged(_ sender: UISlider) {
        guard let p = rightPlayer, let dur = p.currentItem?.duration, CMTIME_IS_NUMERIC(dur) else { return }
        let target = Double(sender.value) * CMTimeGetSeconds(dur)
        rightContainer.updateSlider(value: sender.value, currentTime: target, totalTime: 0)
        p.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    @objc private func editTapped() {
        isEditMode.toggle()
        leftContainer.toggleEditMode(); rightContainer.toggleEditMode()
        editButton.tintColor = isEditMode ? .systemYellow : .white
    }

    @objc private func handleRemoveNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let container = userInfo["container"] as? VideoPaneView else { return }
        if isLinked { linkTapped() } // Unlink first
        if container === leftContainer {
            removeLeftObservers()
            leftPlayer?.pause()
            leftPlayer = nil
            leftURL = nil
            leftContainer.clearPlayer()
            leftContainer.showAddButton()
        } else if container === rightContainer {
            removeRightObservers()
            rightPlayer?.pause()
            rightPlayer = nil
            rightURL = nil
            rightContainer.clearPlayer()
            rightContainer.showAddButton()
        }

        // ✅ Exit edit mode after a removal so the user doesn't stay in editing state
        if isEditMode {
            isEditMode = false
            leftContainer.toggleEditMode()
            rightContainer.toggleEditMode()
            editButton.tintColor = .white
        }

        updateLinkButtonState()
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
        let bothPlayersExist = (leftPlayer != nil && rightPlayer != nil)
        let anyPlayerExists = (leftPlayer != nil || rightPlayer != nil)
        
        // 1. Update Link Button state and color
        linkButton.isEnabled = bothPlayersExist
        linkButton.tintColor = bothPlayersExist ? (isLinked ? .systemYellow : .white) : .systemGray
        
        // 2. Update Edit Button state
        editButton.isEnabled = anyPlayerExists
        
        // 3. FIX: Update Edit Button color so it doesn't stay gray when enabled
        if anyPlayerExists {
            // If enabled, use Yellow if active, otherwise White
            editButton.tintColor = isEditMode ? .systemYellow : .white
        } else {
            // If no videos exist, button must be gray
            editButton.tintColor = .systemGray
            
            // Safety: If all videos were removed, force exit Edit Mode
            if isEditMode {
                isEditMode = false
                leftContainer.toggleEditMode()
                rightContainer.toggleEditMode()
            }
        }
    }

    private func updateStackAxisForOrientation() {
        stackView.axis = view.bounds.width > view.bounds.height ? .horizontal : .vertical
    }
}

// MARK: - Delegate Extensions
extension SplitVideoView: UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIGestureRecognizerDelegate {
    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.view.tag == 1 ? leftContainer.hideLoading() : rightContainer.hideLoading()
        picker.dismiss(animated: true)
    }
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
        defer {
            if picker.view.tag == 1 { leftContainer.hideLoading() } else { rightContainer.hideLoading() }
            picker.dismiss(animated: true)
        }
        guard let url = info[.mediaURL] as? URL else { return }

        if isLinked { linkTapped() }
        
        if picker.view.tag == 1 { // Left Side
            removeLeftObservers() // REMOVE OLD OBSERVER BEFORE CREATING NEW PLAYER
            leftURL = url
            let player = AVPlayer(url: url)
            leftPlayer = player
            leftContainer.showVideo()
            leftContainer.resetPlayState()
            leftContainer.playerView.player = player
            addTimeObserver(for: player, isLeft: true)
            setupDial(for: leftContainer, player: player)
        } else { // Right Side
            removeRightObservers() // REMOVE OLD OBSERVER BEFORE CREATING NEW PLAYER
            rightURL = url
            let player = AVPlayer(url: url)
            rightPlayer = player
            rightContainer.showVideo()
            rightContainer.resetPlayState()
            rightContainer.playerView.player = player
            addTimeObserver(for: player, isLeft: false)
            setupDial(for: rightContainer, player: player)
        }
        updateLinkButtonState()
    }
    
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        let excluded: [UIView] = [
            closeButtonContainer,
            topRightContainer,
            sharedControlsContainer,
            leftContainer.controlsContainer,
            rightContainer.controlsContainer,
            // ADDED: Explicitly exclude add/remove buttons
            leftContainer.addButton,
            leftContainer.removeButton,
            rightContainer.addButton,
            rightContainer.removeButton
        ]
        for v in excluded { if touch.view?.isDescendant(of: v) == true { return false } }
        return true
    }
}

// MARK: - VideoPaneView
private final class VideoPaneView: UIView, UIGestureRecognizerDelegate {
    let playerView = PlayerContainerView()
    let addButton = UIButton(type: .system)
    let removeButton = UIButton(type: .system)
    let controlsContainer = UIView()
    let playPauseButton = UIButton(type: .system)
    
    let scrubSlider: UISlider = {
        let s = UISlider()
        let thumbSize: CGFloat = 20
        let strokeWidth: CGFloat = 1.5
        let padding: CGFloat = 1.5

        let thumbImage = UIGraphicsImageRenderer(size: CGSize(width: thumbSize, height: thumbSize))
            .image { context in
                let fillSize = thumbSize - (strokeWidth * 2) - (padding * 2)
                let fillRect = CGRect(x: padding + strokeWidth, y: padding + strokeWidth, width: fillSize, height: fillSize)
                UIColor.white.setFill()
                UIBezierPath(ovalIn: fillRect).fill()
                
                let strokeRect = CGRect(x: padding, y: padding, width: thumbSize - (padding * 2), height: thumbSize - (padding * 2))
                UIColor.systemYellow.setStroke()
                let strokePath = UIBezierPath(ovalIn: strokeRect)
                strokePath.lineWidth = strokeWidth
                strokePath.stroke()
            }

        s.setThumbImage(thumbImage.withRenderingMode(.alwaysOriginal), for: .normal)
        s.minimumTrackTintColor = .white
        s.maximumTrackTintColor = UIColor(red: 96/255, green: 73/255, blue: 157/255, alpha: 1)
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }()
    
    let timeLabel = UILabel()
    let loadingSpinner = UIActivityIndicatorView(style: .large)
    let frameDial = FrameDial()
    private var isPlaying = false
    var isInEditMode = false
    private let zoomContainer = UIView()

    // Zoom/Pan State
    private var currentScale: CGFloat = 1.0
    private var lastScale: CGFloat = 1.0
    private var currentOffset: CGPoint = .zero
    private var lastOffset: CGPoint = .zero

    init() { super.init(frame: .zero); setup(); setupGestures() }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        backgroundColor = .black; clipsToBounds = true
        playerView.translatesAutoresizingMaskIntoConstraints = false
        
        addButton.setTitle("Add Video", for: .normal)
        addButton.setTitleColor(.white, for: .normal)
        addButton.backgroundColor = UIColor(red: 96/255, green: 73/255, blue: 157/255, alpha: 1)
        addButton.layer.cornerRadius = 12; addButton.translatesAutoresizingMaskIntoConstraints = false
        
        removeButton.setTitle("Remove", for: .normal)
        removeButton.setTitleColor(.white, for: .normal)
        removeButton.backgroundColor = addButton.backgroundColor
        removeButton.layer.cornerRadius = 12; removeButton.translatesAutoresizingMaskIntoConstraints = false; removeButton.isHidden = true
        removeButton.addTarget(self, action: #selector(removeVideoTapped), for: .touchUpInside)

        loadingSpinner.color = .white; loadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        controlsContainer.backgroundColor = UIColor.black.withAlphaComponent(0.7); controlsContainer.layer.cornerRadius = 24; controlsContainer.translatesAutoresizingMaskIntoConstraints = false

        let cfg = UIImage.SymbolConfiguration(pointSize: 28, weight: .bold)
        playPauseButton.setImage(UIImage(systemName: "play.circle.fill", withConfiguration: cfg), for: .normal)
        playPauseButton.tintColor = .white; playPauseButton.translatesAutoresizingMaskIntoConstraints = false; playPauseButton.addTarget(self, action: #selector(togglePlayPause), for: .touchUpInside)

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular); timeLabel.textColor = .white; timeLabel.text = "00:00.00"; timeLabel.translatesAutoresizingMaskIntoConstraints = false

        zoomContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(zoomContainer); zoomContainer.addSubview(playerView); addSubview(addButton); addSubview(removeButton); addSubview(loadingSpinner); addSubview(controlsContainer)
        controlsContainer.addSubview(playPauseButton); controlsContainer.addSubview(scrubSlider); controlsContainer.addSubview(timeLabel); frameDial.translatesAutoresizingMaskIntoConstraints = false; controlsContainer.addSubview(frameDial)

        NSLayoutConstraint.activate([
            zoomContainer.topAnchor.constraint(equalTo: topAnchor), zoomContainer.leadingAnchor.constraint(equalTo: leadingAnchor), zoomContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            playerView.topAnchor.constraint(equalTo: zoomContainer.topAnchor), playerView.leadingAnchor.constraint(equalTo: zoomContainer.leadingAnchor), playerView.trailingAnchor.constraint(equalTo: zoomContainer.trailingAnchor), playerView.bottomAnchor.constraint(equalTo: zoomContainer.bottomAnchor),
            controlsContainer.topAnchor.constraint(equalTo: zoomContainer.bottomAnchor, constant: 8), controlsContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), controlsContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10), controlsContainer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10), controlsContainer.heightAnchor.constraint(equalToConstant: 82),
            addButton.centerXAnchor.constraint(equalTo: playerView.centerXAnchor), addButton.centerYAnchor.constraint(equalTo: playerView.centerYAnchor), addButton.widthAnchor.constraint(equalToConstant: 140), addButton.heightAnchor.constraint(equalToConstant: 44),
            removeButton.centerXAnchor.constraint(equalTo: playerView.centerXAnchor), removeButton.centerYAnchor.constraint(equalTo: playerView.centerYAnchor), removeButton.widthAnchor.constraint(equalToConstant: 140), removeButton.heightAnchor.constraint(equalToConstant: 44),
            loadingSpinner.centerXAnchor.constraint(equalTo: playerView.centerXAnchor), loadingSpinner.centerYAnchor.constraint(equalTo: playerView.centerYAnchor),
            playPauseButton.leadingAnchor.constraint(equalTo: controlsContainer.leadingAnchor, constant: 8), playPauseButton.topAnchor.constraint(equalTo: controlsContainer.topAnchor, constant: 6), playPauseButton.widthAnchor.constraint(equalToConstant: 32), playPauseButton.heightAnchor.constraint(equalToConstant: 32),
            timeLabel.trailingAnchor.constraint(equalTo: controlsContainer.trailingAnchor, constant: -12), timeLabel.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor), timeLabel.widthAnchor.constraint(equalToConstant: 72),
            scrubSlider.leadingAnchor.constraint(equalTo: playPauseButton.trailingAnchor, constant: 10), scrubSlider.trailingAnchor.constraint(equalTo: timeLabel.leadingAnchor, constant: -10), scrubSlider.centerYAnchor.constraint(equalTo: playPauseButton.centerYAnchor),
            frameDial.centerXAnchor.constraint(equalTo: scrubSlider.centerXAnchor), frameDial.widthAnchor.constraint(equalTo: scrubSlider.widthAnchor, multiplier: 0.75), frameDial.topAnchor.constraint(equalTo: playPauseButton.bottomAnchor, constant: 4), frameDial.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    private func setupGestures() {
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)
        
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        addGestureRecognizer(pan)
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        if gesture.state == .began { lastScale = currentScale }
        currentScale = max(1.0, lastScale * gesture.scale)
        updateTransform()
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { lastOffset = currentOffset }
        let translation = gesture.translation(in: self)
        currentOffset = CGPoint(x: lastOffset.x + translation.x, y: lastOffset.y + translation.y)
        updateTransform()
    }

    private func updateTransform() {
        let scaleT = CGAffineTransform(scaleX: currentScale, y: currentScale)
        let translateT = CGAffineTransform(translationX: currentOffset.x, y: currentOffset.y)
        playerView.transform = scaleT.concatenating(translateT)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
    
    // NEW: Prevents zoom/pan when touching the scrub bar or frame dial container
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let touchView = touch.view else { return true }
        
        // Exclude the controls container and any buttons from triggering the drag/zoom
        let excludedViews: [UIView] = [controlsContainer, addButton, removeButton]
        
        for view in excludedViews {
            if touchView.isDescendant(of: view) {
                return false
            }
        }
        return true
    }

    @objc private func togglePlayPause() {
        guard let p = playerView.player else { return }
        p.rate > 0 ? p.pause() : p.play(); isPlaying = (p.rate > 0); updatePlayPauseIcon()
    }
    func updatePlayPauseIcon() {
        let name = isPlaying ? "pause.circle.fill" : "play.circle.fill"
        let cfg = UIImage.SymbolConfiguration(pointSize: 28, weight: .bold)
        playPauseButton.setImage(UIImage(systemName: name, withConfiguration: cfg), for: .normal)
    }
    func showVideo() { addButton.isHidden = true; removeButton.isHidden = true; controlsContainer.isHidden = false }
    func showAddButton() { addButton.isHidden = false; removeButton.isHidden = true; controlsContainer.isHidden = true }
    func showLoading() { addButton.isHidden = true; loadingSpinner.startAnimating(); loadingSpinner.isHidden = false }
    func hideLoading() { loadingSpinner.stopAnimating(); loadingSpinner.isHidden = true; if playerView.player == nil { showAddButton() } }
    func toggleEditMode() { isInEditMode.toggle(); isInEditMode ? showRemoveButton() : (playerView.player != nil ? showVideo() : showAddButton()) }
    func showRemoveButton() { addButton.isHidden = true; removeButton.isHidden = false; controlsContainer.isHidden = true }
    func clearPlayer() { playerView.player = nil; isPlaying = false; updatePlayPauseIcon() }
    func resetPlayState() { isPlaying = false; updatePlayPauseIcon(); scrubSlider.value = 0; timeLabel.text = "00:00.00" }
    @objc private func removeVideoTapped() { NotificationCenter.default.post(name: Notification.Name("VideoPaneViewRemoveTapped"), object: nil, userInfo: ["container": self]) }
    func updateSlider(value: Float, currentTime: Double, totalTime: Double) { timeLabel.text = formatTime(currentTime); if !scrubSlider.isTracking { scrubSlider.value = value } }
    private func formatTime(_ secs: Double) -> String {
        let m = Int(secs) / 60, s = Int(secs) % 60, h = Int(secs.truncatingRemainder(dividingBy: 1.0) * 100)
        return String(format: "%02d:%02d.%02d", m, s, h)
    }
}

private final class PlayerContainerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    var player: AVPlayer? { get { playerLayer.player } set { playerLayer.videoGravity = .resizeAspect; playerLayer.player = newValue } }
}
