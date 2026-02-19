import UIKit
import AVFoundation
import Photos

class DelayedCameraView: UIView {

    // MARK: - Capture

    private var captureSession: AVCaptureSession!
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var videoDataOutput: AVCaptureVideoDataOutput?
    private var isFrontCamera: Bool = false
    private var currentDevice: AVCaptureDevice?
    var onSessionStopped: (() -> Void)?

    // MARK: - Buffer

    private var videoFileBuffer: VideoFileBuffer?

    // MARK: - State

    private var delaySeconds: Int = 7
    private var isActive: Bool = false
    private var isShowingDelayed: Bool = false
    private var isPaused: Bool = false

    // MARK: - Recording indicator

    private var recordingDurationTimer: Timer?
    private var recordingStartTime: TimeInterval = 0

    // MARK: - Live-delay display

    private var displayTimer: Timer?
    private var displayImageView: UIImageView!

    // MARK: - Activity check

    private var activityCheckTimer: Timer?
    private var activityCountdownTimer: Timer?
    private var activityTimeRemaining: Int = 60
    private let activityCheckInterval: TimeInterval = 2700

    // MARK: - AVPlayer (scrub + playback)

    /// The player used for both scrubbing (seek while paused) and
    /// looped playback (play.rate = 1).
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var playerTimeObserver: Any?
    private var playerLoopObserver: NSObjectProtocol?
    private var playerBoundaryObserver: Any?

    /// True while a seek is already in-flight on the player.
    /// We gate new scrub seeks on this flag so we never stack them.
    private var isSeeking: Bool = false
    /// The frame index the user last requested while a seek was in flight.
    /// If non-nil it is dispatched as soon as the current seek completes.
    private var pendingScrubIndex: Int?

    // MARK: - Scrub / loop

    private var scrubberPosition: Int = 0   // global frame index
    private var isLooping: Bool = false

    // MARK: - Clip selection

    private var clipStartIndex: Int    = 0
    private var clipEndIndex: Int      = 0
    private var isClipMode: Bool       = false
    private var clipPlayheadPosition: Int = 0

    // MARK: - Pan gesture tracking

    private var initialLeftPosition: CGFloat    = 0
    private var initialRightPosition: CGFloat   = 0
    private var initialPlayheadPosition: CGFloat = 0
    private var initialClipStartIndex: Int      = 0
    private var initialClipEndIndex: Int        = 0
    private var initialClipPlayheadPosition: Int = 0
    private var isDraggingHandle: Bool          = false
    private var lastUpdateTime: TimeInterval    = 0

    // MARK: - Display

    private var currentDisplayFrameIndex: Int = 0
    
    private func formatTime(_ seconds: Float) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let frac = Int((seconds - Float(Int(seconds))) * 100)
        return String(format: "%02d:%02d.%02d", mins, secs, frac)
    }

    // MARK: - Config

    //private let scrubDurationSeconds: Int = 300
    private var scrubDurationSeconds: Int {
        Settings.shared.bufferDurationSeconds
    }
    private let handleWidth: CGFloat      = 20
    private lazy var captureQueue = DispatchQueue(
        label: "com.loopr.capture", qos: .userInteractive)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - UI — countdown / pause overlay

    private let countdownLabel: UILabel = {
        let l = UILabel()
        l.font = .systemFont(ofSize: 120, weight: .bold)
        l.textColor = .white
        l.textAlignment = .center
        l.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        l.layer.cornerRadius = 20
        l.clipsToBounds = true
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let countdownStopButton: UIButton = {
        let b = UIButton(type: .system)
        let cfg = UIImage.SymbolConfiguration(pointSize: 90, weight: .bold)
        b.setImage(UIImage(systemName: "xmark.circle.fill", withConfiguration: cfg), for: .normal)
        b.tintColor = .white
        b.backgroundColor = .black
        b.layer.borderWidth = 2
        b.layer.borderColor = UIColor.black.cgColor
        b.layer.cornerRadius = 60
        b.clipsToBounds = true
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let livePauseButton: UIButton = {
        let b = UIButton(type: .system)
        let cfg = UIImage.SymbolConfiguration(pointSize: 90, weight: .bold)
        b.setImage(UIImage(systemName: "pause.circle.fill", withConfiguration: cfg), for: .normal)
        b.tintColor = .white
        b.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        b.layer.cornerRadius = 60
        b.clipsToBounds = true
        b.translatesAutoresizingMaskIntoConstraints = false
        b.alpha = 0
        return b
    }()

    private let successFeedbackView: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        v.layer.cornerRadius = 20
        v.clipsToBounds = true
        v.translatesAutoresizingMaskIntoConstraints = false
        v.alpha = 0
        let cfg = UIImage.SymbolConfiguration(pointSize: 120, weight: .bold)
        let iv = UIImageView(image: UIImage(systemName: "checkmark", withConfiguration: cfg))
        iv.tintColor = .white
        iv.contentMode = .center
        iv.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(iv)
        NSLayoutConstraint.activate([
            iv.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            iv.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            iv.widthAnchor.constraint(equalToConstant: 150),
            iv.heightAnchor.constraint(equalToConstant: 150)
        ])
        return v
    }()

    // MARK: - UI — recording indicator

    private let recordingIndicator: UIView = {
        let c = UIView()
        c.backgroundColor = .systemRed
        c.layer.cornerRadius = 18
        c.translatesAutoresizingMaskIntoConstraints = false
        c.alpha = 0

        let dot = UIView(); dot.backgroundColor = .white; dot.layer.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false; dot.tag = 999

        let live = UILabel(); live.text = "LIVE"; live.textColor = .white
        live.font = .systemFont(ofSize: 14, weight: .bold)
        live.translatesAutoresizingMaskIntoConstraints = false; live.tag = 998

        let bg = UIView(); bg.backgroundColor = .white; bg.layer.cornerRadius = 8
        bg.translatesAutoresizingMaskIntoConstraints = false

        let delay = UILabel(); delay.text = "-7s"
        delay.textColor = .systemRed
        delay.font = .monospacedDigitSystemFont(ofSize: 12, weight: .heavy)
        delay.textAlignment = .center
        delay.translatesAutoresizingMaskIntoConstraints = false; delay.tag = 997

        let dur = UILabel(); dur.text = "00:00:00"; dur.textColor = .white
        dur.font = .monospacedDigitSystemFont(ofSize: 14, weight: .light)
        dur.translatesAutoresizingMaskIntoConstraints = false; dur.tag = 996

        c.addSubview(dot); c.addSubview(live); c.addSubview(bg)
        bg.addSubview(delay); c.addSubview(dur)

        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 12),
            dot.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            live.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            live.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            bg.leadingAnchor.constraint(equalTo: live.trailingAnchor, constant: 5),
            bg.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            delay.topAnchor.constraint(equalTo: bg.topAnchor, constant: 4),
            delay.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -4),
            delay.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 6),
            delay.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -6),
            dur.leadingAnchor.constraint(equalTo: bg.trailingAnchor, constant: 6),
            dur.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -12),
            dur.centerYAnchor.constraint(equalTo: c.centerYAnchor)
        ])
        return c
    }()

    // MARK: - UI — activity alert

    private lazy var activityAlertContainer: UIView = {
        let c = UIView()
        c.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        c.layer.cornerRadius = 20; c.clipsToBounds = true
        c.translatesAutoresizingMaskIntoConstraints = false; c.alpha = 0

        let msg = UILabel()
        msg.text = "Are you still there?"
        msg.font = .systemFont(ofSize: 32, weight: .semibold)
        msg.textColor = .white; msg.textAlignment = .center; msg.numberOfLines = 0
        msg.translatesAutoresizingMaskIntoConstraints = false

        let yes = UIButton(type: .system)
        yes.setTitle("Yes, Continue", for: .normal)
        yes.titleLabel?.font = .systemFont(ofSize: 20, weight: .bold)
        yes.setTitleColor(.white, for: .normal)
        yes.backgroundColor = UIColor(red: 96/255, green: 73/255, blue: 157/255, alpha: 1)
        yes.layer.cornerRadius = 12; yes.layer.borderWidth = 1
        yes.layer.borderColor = UIColor.black.cgColor; yes.clipsToBounds = true
        yes.translatesAutoresizingMaskIntoConstraints = false; yes.tag = 1001

        let prog = UIView()
        prog.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        prog.translatesAutoresizingMaskIntoConstraints = false; prog.tag = 1002
        yes.insertSubview(prog, at: 0)

        let no = UIButton(type: .system)
        no.setTitle("No, Pause", for: .normal)
        no.titleLabel?.font = .systemFont(ofSize: 16, weight: .regular)
        no.setTitleColor(UIColor.white.withAlphaComponent(0.7), for: .normal)
        no.translatesAutoresizingMaskIntoConstraints = false; no.tag = 1003

        c.addSubview(msg); c.addSubview(yes); c.addSubview(no)
        NSLayoutConstraint.activate([
            msg.topAnchor.constraint(equalTo: c.topAnchor, constant: 40),
            msg.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 30),
            msg.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -30),
            yes.topAnchor.constraint(equalTo: msg.bottomAnchor, constant: 40),
            yes.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 30),
            yes.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -30),
            yes.heightAnchor.constraint(equalToConstant: 56),
            prog.leadingAnchor.constraint(equalTo: yes.leadingAnchor),
            prog.topAnchor.constraint(equalTo: yes.topAnchor),
            prog.bottomAnchor.constraint(equalTo: yes.bottomAnchor),
            no.topAnchor.constraint(equalTo: yes.bottomAnchor, constant: 10),
            no.centerXAnchor.constraint(equalTo: c.centerXAnchor),
            no.bottomAnchor.constraint(equalTo: c.bottomAnchor, constant: -10)
        ])
        yes.addTarget(self, action: #selector(activityYesTapped), for: .touchUpInside)
        no.addTarget(self,  action: #selector(activityNoTapped),  for: .touchUpInside)
        let tap = UITapGestureRecognizer(target: self,
                                         action: #selector(activityBackgroundTapped(_:)))
        c.addGestureRecognizer(tap)
        return c
    }()

    // MARK: - UI — controls container

    private let controlsContainer: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        v.layer.cornerRadius = 40
        v.translatesAutoresizingMaskIntoConstraints = false
        v.alpha = 0
        return v
    }()

    private let playPauseButton: UIButton = {
        let b = UIButton(type: .system)
        let cfg = UIImage.SymbolConfiguration(pointSize: 32, weight: .bold)
        b.setImage(UIImage(systemName: "play.circle.fill", withConfiguration: cfg), for: .normal)
        b.tintColor = .white
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let timelineContainer: UIView = {
        let v = UIView(); v.backgroundColor = .clear
        v.translatesAutoresizingMaskIntoConstraints = false; v.clipsToBounds = false
        return v
    }()

    private let scrubberBackground: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor(red: 96/255, green: 73/255, blue: 157/255, alpha: 1)
        v.layer.cornerRadius = 6
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let scrubberPlayhead: UIView = {
        let v = UIView(); v.backgroundColor = .white
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isUserInteractionEnabled = false
        return v
    }()

    private let scrubberPlayheadKnob: UIView = {
        let v = UIView(); v.backgroundColor = .white; v.layer.cornerRadius = 8
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isUserInteractionEnabled = false
        return v
    }()

    private let scrubberTouchArea: UIView = {
        let v = UIView(); v.backgroundColor = .clear
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isUserInteractionEnabled = true
        return v
    }()

    private let leftDimView: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor(red: 96/255, green: 73/255, blue: 157/255, alpha: 0.5)
        v.translatesAutoresizingMaskIntoConstraints = false; v.isHidden = true
        v.layer.cornerRadius = 6
        v.layer.maskedCorners = [.layerMinXMinYCorner, .layerMinXMaxYCorner]
        return v
    }()

    private let rightDimView: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor(red: 96/255, green: 73/255, blue: 157/255, alpha: 0.5)
        v.translatesAutoresizingMaskIntoConstraints = false; v.isHidden = true
        v.layer.cornerRadius = 6
        v.layer.maskedCorners = [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]
        return v
    }()

    private let clipRegionBackground: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor(red: 96/255, green: 73/255, blue: 157/255, alpha: 1)
        v.layer.cornerRadius = 6
        v.translatesAutoresizingMaskIntoConstraints = false; v.isHidden = true
        return v
    }()

    private let leftTrimHandle: UIView = {
        let v = UIView(); v.backgroundColor = .systemYellow; v.layer.cornerRadius = 3
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true; v.isUserInteractionEnabled = true
        let ch = UIImageView(image: UIImage(systemName: "chevron.compact.left"))
        ch.tintColor = .black; ch.contentMode = .center
        ch.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(ch)
        NSLayoutConstraint.activate([
            ch.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            ch.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            ch.widthAnchor.constraint(equalToConstant: 12),
            ch.heightAnchor.constraint(equalToConstant: 20)
        ])
        return v
    }()

    private let rightTrimHandle: UIView = {
        let v = UIView(); v.backgroundColor = .systemYellow; v.layer.cornerRadius = 3
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true; v.isUserInteractionEnabled = true
        let ch = UIImageView(image: UIImage(systemName: "chevron.compact.right"))
        ch.tintColor = .black; ch.contentMode = .center
        ch.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(ch)
        NSLayoutConstraint.activate([
            ch.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            ch.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            ch.widthAnchor.constraint(equalToConstant: 12),
            ch.heightAnchor.constraint(equalToConstant: 20)
        ])
        return v
    }()

    private let topBorder: UIView = {
        let v = UIView(); v.backgroundColor = .systemYellow
        v.translatesAutoresizingMaskIntoConstraints = false; v.isHidden = true
        return v
    }()

    private let bottomBorder: UIView = {
        let v = UIView(); v.backgroundColor = .systemYellow
        v.translatesAutoresizingMaskIntoConstraints = false; v.isHidden = true
        return v
    }()

    private let clipPlayhead: UIView = {
        let v = UIView(); v.backgroundColor = .white
        v.translatesAutoresizingMaskIntoConstraints = false
        v.isHidden = true; v.isUserInteractionEnabled = false
        return v
    }()

    private let clipPlayheadKnob: UIView = {
        let v = UIView(); v.backgroundColor = .white; v.layer.cornerRadius = 8
        v.layer.borderWidth = 2; v.layer.borderColor = UIColor.systemYellow.cgColor
        v.translatesAutoresizingMaskIntoConstraints = false; v.isUserInteractionEnabled = false
        return v
    }()

    private let playheadTouchArea: UIView = {
        let v = UIView(); v.backgroundColor = .clear
        v.translatesAutoresizingMaskIntoConstraints = false; v.isUserInteractionEnabled = true
        return v
    }()

    private let timeLabel: UILabel = {
        let l = UILabel(); l.text = "LIVE"
        l.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        l.textColor = .white
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let clipSaveButton: UIButton = {
        let b = UIButton(type: .system)
        let cfg = UIImage.SymbolConfiguration(pointSize: 32, weight: .bold)
        b.setImage(UIImage(systemName: "film.circle.fill", withConfiguration: cfg), for: .normal)
        b.tintColor = .white; b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let topRightButtonContainer: UIView = {
        let v = UIView()
        v.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        v.layer.cornerRadius = 32
        v.translatesAutoresizingMaskIntoConstraints = false; v.alpha = 0
        return v
    }()

    private let stopSessionButton: UIButton = {
        let b = UIButton(type: .system)
        let cfg = UIImage.SymbolConfiguration(pointSize: 32, weight: .bold)
        b.setImage(UIImage(systemName: "xmark.circle.fill", withConfiguration: cfg), for: .normal)
        b.tintColor = .systemRed; b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let restartButton: UIButton = {
        let b = UIButton(type: .system)
        let cfg = UIImage.SymbolConfiguration(pointSize: 32, weight: .bold)
        b.setImage(UIImage(systemName: "arrow.clockwise.circle.fill", withConfiguration: cfg), for: .normal)
        b.tintColor = .systemGreen; b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let cancelClipButton: UIButton = {
        let b = UIButton(type: .system)
        b.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        b.layer.cornerRadius = 18; b.clipsToBounds = true
        b.setTitle("Cancel", for: .normal)
        b.titleLabel?.font = .systemFont(ofSize: 16, weight: .semibold)
        b.setTitleColor(.white, for: .normal)
        b.contentEdgeInsets = UIEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        b.translatesAutoresizingMaskIntoConstraints = false; b.isHidden = true
        return b
    }()
    
    private let bufferLimitLabel: UIButton = {
        let b = UIButton(type: .system)
        b.titleLabel?.font = UIFont.systemFont(ofSize: 12, weight: .medium)
        b.setTitleColor(.white, for: .normal)
        b.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.85)
        b.layer.cornerRadius = 12
        b.contentEdgeInsets = UIEdgeInsets(top: 4, left: 14, bottom: 4, right: 14)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.isUserInteractionEnabled = false
        b.alpha = 0
        return b
    }()

    // MARK: - Layout constraints (mutable)

    private var leftHandleConstraint: NSLayoutConstraint?
    private var rightHandleConstraint: NSLayoutConstraint?
    private var playheadConstraint: NSLayoutConstraint?
    private var playheadWidthConstraint: NSLayoutConstraint?
    private var clipBackgroundLeadingConstraint: NSLayoutConstraint?
    private var clipBackgroundTrailingConstraint: NSLayoutConstraint?
    private var scrubberPlayheadConstraint: NSLayoutConstraint?
    private var scrubberTouchAreaConstraint: NSLayoutConstraint?
    private var activityProgressConstraint: NSLayoutConstraint?

    // MARK: - Hide-controls timer

    private var hideControlsTimer: Timer?

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black

        displayImageView = UIImageView(frame: bounds)
        displayImageView.contentMode = .scaleAspectFill
        displayImageView.clipsToBounds = true
        displayImageView.backgroundColor = .clear
        displayImageView.alpha = 0
        displayImageView.isUserInteractionEnabled = false
        addSubview(displayImageView)

        addSubview(countdownLabel)
        addSubview(countdownStopButton)
        addSubview(livePauseButton)
        addSubview(successFeedbackView)
        addSubview(cancelClipButton)
        setupControls()
        addSubview(activityAlertContainer)

        NSLayoutConstraint.activate([
            countdownLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            countdownLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            countdownLabel.widthAnchor.constraint(equalToConstant: 200),
            countdownLabel.heightAnchor.constraint(equalToConstant: 200),

            countdownStopButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            countdownStopButton.bottomAnchor.constraint(
                equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -40),
            countdownStopButton.widthAnchor.constraint(equalToConstant: 120),
            countdownStopButton.heightAnchor.constraint(equalToConstant: 120),

            livePauseButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            livePauseButton.bottomAnchor.constraint(
                equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -40),
            livePauseButton.widthAnchor.constraint(equalToConstant: 120),
            livePauseButton.heightAnchor.constraint(equalToConstant: 120),

            successFeedbackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            successFeedbackView.centerYAnchor.constraint(equalTo: centerYAnchor),
            successFeedbackView.widthAnchor.constraint(equalToConstant: 200),
            successFeedbackView.heightAnchor.constraint(equalToConstant: 200),

            cancelClipButton.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: 20),
            cancelClipButton.topAnchor.constraint(
                equalTo: safeAreaLayoutGuide.topAnchor, constant: 10),

            activityAlertContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            activityAlertContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            activityAlertContainer.widthAnchor.constraint(equalToConstant: 340)
        ])

        countdownStopButton.addTarget(self, action: #selector(countdownStopTapped),  for: .touchUpInside)
        livePauseButton.addTarget(self,     action: #selector(livePauseTapped),       for: .touchUpInside)

        NotificationCenter.default.addObserver(
            self, selector: #selector(orientationDidChange),
            name: UIDevice.orientationDidChangeNotification, object: nil)

        addGestureRecognizer(
            UITapGestureRecognizer(target: self, action: #selector(handleTap)))

        print("🎬 DelayedCameraView initialized")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        hideControlsTimer?.invalidate()
        recordingDurationTimer?.invalidate()
        activityCheckTimer?.invalidate()
        activityCountdownTimer?.invalidate()
        tearDownPlayer()
        videoFileBuffer?.cleanup()
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        displayImageView.frame = bounds
        previewLayer?.frame    = bounds
        playerLayer?.frame     = bounds
        layer.layoutIfNeeded()
        if isClipMode {
            updateClipHandlePositions()
            updatePlayheadPosition()
        } else if isPaused {
            updateScrubberPlayheadPosition()
        }
    }

    // MARK: - Controls setup

    private func setupControls() {
        addSubview(controlsContainer)
        addSubview(recordingIndicator)
        addSubview(topRightButtonContainer)
        addSubview(bufferLimitLabel)

        controlsContainer.addSubview(playPauseButton)
        controlsContainer.addSubview(timelineContainer)
        controlsContainer.addSubview(timeLabel)
        controlsContainer.addSubview(clipSaveButton)

        topRightButtonContainer.addSubview(restartButton)
        topRightButtonContainer.addSubview(stopSessionButton)

        timelineContainer.addSubview(scrubberBackground)
        timelineContainer.addSubview(scrubberPlayhead)
        scrubberPlayhead.addSubview(scrubberPlayheadKnob)
        timelineContainer.addSubview(scrubberTouchArea)
        timelineContainer.addSubview(clipRegionBackground)
        timelineContainer.addSubview(leftDimView)
        timelineContainer.addSubview(rightDimView)
        timelineContainer.addSubview(topBorder)
        timelineContainer.addSubview(bottomBorder)
        timelineContainer.addSubview(playheadTouchArea)
        timelineContainer.addSubview(leftTrimHandle)
        timelineContainer.addSubview(rightTrimHandle)
        timelineContainer.addSubview(clipPlayhead)
        clipPlayhead.addSubview(clipPlayheadKnob)

        playPauseButton.addTarget(self,   action: #selector(playPauseTapped),        for: .touchUpInside)
        stopSessionButton.addTarget(self, action: #selector(stopSessionTapped),      for: .touchUpInside)
        clipSaveButton.addTarget(self,    action: #selector(clipSaveButtonTapped),   for: .touchUpInside)
        restartButton.addTarget(self,     action: #selector(restartButtonTapped),    for: .touchUpInside)
        cancelClipButton.addTarget(self,  action: #selector(cancelClipTapped),       for: .touchUpInside)

        let leftPan = UIPanGestureRecognizer(target: self, action: #selector(handleLeftTrimPan(_:)))
        leftTrimHandle.addGestureRecognizer(leftPan)
        let rightPan = UIPanGestureRecognizer(target: self, action: #selector(handleRightTrimPan(_:)))
        rightTrimHandle.addGestureRecognizer(rightPan)
        let playheadPan = UIPanGestureRecognizer(target: self, action: #selector(handlePlayheadPan(_:)))
        playheadTouchArea.addGestureRecognizer(playheadPan)
        let scrubberPan = UIPanGestureRecognizer(target: self, action: #selector(handleScrubberPan(_:)))
        scrubberPan.delegate = self
        timelineContainer.addGestureRecognizer(scrubberPan)
        let timelineTap = UITapGestureRecognizer(target: self, action: #selector(handleTimelineTap(_:)))
        timelineTap.cancelsTouchesInView = false
        timelineContainer.addGestureRecognizer(timelineTap)

        NSLayoutConstraint.activate([
            recordingIndicator.topAnchor.constraint(
                equalTo: safeAreaLayoutGuide.topAnchor, constant: 10),
            recordingIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            recordingIndicator.heightAnchor.constraint(equalToConstant: 36),
            recordingIndicator.widthAnchor.constraint(greaterThanOrEqualToConstant: 100),

            topRightButtonContainer.topAnchor.constraint(
                equalTo: safeAreaLayoutGuide.topAnchor, constant: 10),
            topRightButtonContainer.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -20),
            topRightButtonContainer.heightAnchor.constraint(equalToConstant: 64),
            topRightButtonContainer.widthAnchor.constraint(equalToConstant: 108),
            restartButton.leadingAnchor.constraint(
                equalTo: topRightButtonContainer.leadingAnchor, constant: 10),
            restartButton.centerYAnchor.constraint(equalTo: topRightButtonContainer.centerYAnchor),
            restartButton.widthAnchor.constraint(equalToConstant: 44),
            restartButton.heightAnchor.constraint(equalToConstant: 44),
            stopSessionButton.trailingAnchor.constraint(
                equalTo: topRightButtonContainer.trailingAnchor, constant: -10),
            stopSessionButton.centerYAnchor.constraint(equalTo: topRightButtonContainer.centerYAnchor),
            stopSessionButton.widthAnchor.constraint(equalToConstant: 44),
            stopSessionButton.heightAnchor.constraint(equalToConstant: 44),

            controlsContainer.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: 20),
            controlsContainer.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -20),
            controlsContainer.bottomAnchor.constraint(
                equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -10),
            controlsContainer.heightAnchor.constraint(equalToConstant: 80),

            playPauseButton.leadingAnchor.constraint(
                equalTo: controlsContainer.leadingAnchor, constant: 20),
            playPauseButton.centerYAnchor.constraint(equalTo: controlsContainer.centerYAnchor),
            playPauseButton.widthAnchor.constraint(equalToConstant: 44),
            playPauseButton.heightAnchor.constraint(equalToConstant: 44),

            clipSaveButton.trailingAnchor.constraint(
                equalTo: controlsContainer.trailingAnchor, constant: -20),
            clipSaveButton.centerYAnchor.constraint(equalTo: controlsContainer.centerYAnchor),
            clipSaveButton.widthAnchor.constraint(equalToConstant: 44),
            clipSaveButton.heightAnchor.constraint(equalToConstant: 44),

            timeLabel.trailingAnchor.constraint(
                equalTo: clipSaveButton.leadingAnchor, constant: -5),
            timeLabel.centerYAnchor.constraint(equalTo: controlsContainer.centerYAnchor),
            timeLabel.widthAnchor.constraint(equalToConstant: 75),

            timelineContainer.leadingAnchor.constraint(
                equalTo: playPauseButton.trailingAnchor, constant: 20),
            timelineContainer.trailingAnchor.constraint(
                equalTo: timeLabel.leadingAnchor, constant: -20),
            timelineContainer.centerYAnchor.constraint(equalTo: controlsContainer.centerYAnchor),
            timelineContainer.heightAnchor.constraint(equalToConstant: 44),

            scrubberBackground.leadingAnchor.constraint(equalTo: timelineContainer.leadingAnchor),
            scrubberBackground.trailingAnchor.constraint(equalTo: timelineContainer.trailingAnchor),
            scrubberBackground.topAnchor.constraint(equalTo: timelineContainer.topAnchor),
            scrubberBackground.bottomAnchor.constraint(equalTo: timelineContainer.bottomAnchor),

            scrubberPlayhead.topAnchor.constraint(equalTo: timelineContainer.topAnchor),
            scrubberPlayhead.bottomAnchor.constraint(equalTo: timelineContainer.bottomAnchor),
            scrubberPlayhead.widthAnchor.constraint(equalToConstant: 3),
            scrubberPlayheadKnob.centerXAnchor.constraint(equalTo: scrubberPlayhead.centerXAnchor),
            scrubberPlayheadKnob.topAnchor.constraint(
                equalTo: scrubberPlayhead.topAnchor, constant: -6),
            scrubberPlayheadKnob.widthAnchor.constraint(equalToConstant: 16),
            scrubberPlayheadKnob.heightAnchor.constraint(equalToConstant: 16),

            scrubberTouchArea.topAnchor.constraint(equalTo: timelineContainer.topAnchor),
            scrubberTouchArea.bottomAnchor.constraint(equalTo: timelineContainer.bottomAnchor),
            scrubberTouchArea.widthAnchor.constraint(equalToConstant: 44),

            clipRegionBackground.topAnchor.constraint(equalTo: timelineContainer.topAnchor),
            clipRegionBackground.bottomAnchor.constraint(equalTo: timelineContainer.bottomAnchor),

            leftDimView.leadingAnchor.constraint(equalTo: timelineContainer.leadingAnchor),
            leftDimView.topAnchor.constraint(equalTo: timelineContainer.topAnchor),
            leftDimView.bottomAnchor.constraint(equalTo: timelineContainer.bottomAnchor),
            leftDimView.trailingAnchor.constraint(equalTo: leftTrimHandle.leadingAnchor),

            rightDimView.trailingAnchor.constraint(equalTo: timelineContainer.trailingAnchor),
            rightDimView.topAnchor.constraint(equalTo: timelineContainer.topAnchor),
            rightDimView.bottomAnchor.constraint(equalTo: timelineContainer.bottomAnchor),
            rightDimView.leadingAnchor.constraint(equalTo: rightTrimHandle.trailingAnchor),

            topBorder.leadingAnchor.constraint(equalTo: leftTrimHandle.trailingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: rightTrimHandle.leadingAnchor),
            topBorder.topAnchor.constraint(equalTo: timelineContainer.topAnchor),
            topBorder.heightAnchor.constraint(equalToConstant: 3),

            bottomBorder.leadingAnchor.constraint(equalTo: leftTrimHandle.trailingAnchor),
            bottomBorder.trailingAnchor.constraint(equalTo: rightTrimHandle.leadingAnchor),
            bottomBorder.bottomAnchor.constraint(equalTo: timelineContainer.bottomAnchor),
            bottomBorder.heightAnchor.constraint(equalToConstant: 3),

            leftTrimHandle.topAnchor.constraint(equalTo: timelineContainer.topAnchor),
            leftTrimHandle.bottomAnchor.constraint(equalTo: timelineContainer.bottomAnchor),
            leftTrimHandle.widthAnchor.constraint(equalToConstant: handleWidth),

            rightTrimHandle.topAnchor.constraint(equalTo: timelineContainer.topAnchor),
            rightTrimHandle.bottomAnchor.constraint(equalTo: timelineContainer.bottomAnchor),
            rightTrimHandle.widthAnchor.constraint(equalToConstant: handleWidth),

            clipPlayhead.topAnchor.constraint(equalTo: timelineContainer.topAnchor),
            clipPlayhead.bottomAnchor.constraint(equalTo: timelineContainer.bottomAnchor),
            clipPlayheadKnob.centerXAnchor.constraint(equalTo: clipPlayhead.centerXAnchor),
            clipPlayheadKnob.topAnchor.constraint(
                equalTo: clipPlayhead.topAnchor, constant: -6),
            clipPlayheadKnob.widthAnchor.constraint(equalToConstant: 16),
            clipPlayheadKnob.heightAnchor.constraint(equalToConstant: 16),

            playheadTouchArea.centerXAnchor.constraint(equalTo: clipPlayhead.centerXAnchor),
            playheadTouchArea.topAnchor.constraint(equalTo: timelineContainer.topAnchor),
            playheadTouchArea.bottomAnchor.constraint(equalTo: timelineContainer.bottomAnchor),
            playheadTouchArea.widthAnchor.constraint(equalToConstant: 44),
            
            bufferLimitLabel.topAnchor.constraint(equalTo: controlsContainer.bottomAnchor, constant: 3),
            bufferLimitLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            bufferLimitLabel.heightAnchor.constraint(equalToConstant: 24)
        ])

        leftHandleConstraint  = leftTrimHandle.leadingAnchor.constraint(
            equalTo: timelineContainer.leadingAnchor)
        rightHandleConstraint = rightTrimHandle.trailingAnchor.constraint(
            equalTo: timelineContainer.trailingAnchor)
        playheadConstraint    = clipPlayhead.leadingAnchor.constraint(
            equalTo: timelineContainer.leadingAnchor)
        playheadWidthConstraint = clipPlayhead.widthAnchor.constraint(equalToConstant: 3)
        clipBackgroundLeadingConstraint  = clipRegionBackground.leadingAnchor.constraint(
            equalTo: leftTrimHandle.trailingAnchor)
        clipBackgroundTrailingConstraint = clipRegionBackground.trailingAnchor.constraint(
            equalTo: rightTrimHandle.leadingAnchor)
        scrubberPlayheadConstraint  = scrubberPlayhead.leadingAnchor.constraint(
            equalTo: timelineContainer.leadingAnchor)
        scrubberTouchAreaConstraint = scrubberTouchArea.leadingAnchor.constraint(
            equalTo: timelineContainer.leadingAnchor, constant: -22)

        [leftHandleConstraint, rightHandleConstraint, playheadConstraint,
         playheadWidthConstraint, clipBackgroundLeadingConstraint,
         clipBackgroundTrailingConstraint, scrubberPlayheadConstraint,
         scrubberTouchAreaConstraint].forEach { $0?.isActive = true }
    }

    // MARK: - Tap & controls visibility

    @objc private func handleTap() {
        guard isShowingDelayed else { return }
        restartActivityCheckTimer()
        if !isPaused {
            livePauseButton.alpha == 0 ? showLivePauseButton() : hideLivePauseButton()
        }
    }

    private func showLivePauseButton() {
        UIView.animate(withDuration: 0.3) { self.livePauseButton.alpha = 1 }
        resetHideControlsTimer()
    }

    private func hideLivePauseButton() {
        UIView.animate(withDuration: 0.3) { self.livePauseButton.alpha = 0 }
    }

    private func showControls() {
        UIView.animate(withDuration: 0.3) {
            self.controlsContainer.alpha      = 1
            self.topRightButtonContainer.alpha = 1
        }
    }

    private func hideControls() {
        UIView.animate(withDuration: 0.3) {
            self.controlsContainer.alpha      = 0
            self.topRightButtonContainer.alpha = 0
            self.bufferLimitLabel.alpha        = 0
        }
    }

    private func resetHideControlsTimer() {
        hideControlsTimer?.invalidate()
        hideControlsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) {
            [weak self] _ in
            guard let self else { return }
            if !self.isPaused { self.hideLivePauseButton() }
        }
    }

    // MARK: - Recording indicator

    private func startRecordingIndicator() {
        UIView.animate(withDuration: 0.3) { self.recordingIndicator.alpha = 1 }
        if let dot = recordingIndicator.viewWithTag(999) {
            let b = CABasicAnimation(keyPath: "opacity")
            b.fromValue = 1.0; b.toValue = 0.0; b.duration = 0.8
            b.repeatCount = .infinity; b.autoreverses = true
            dot.layer.add(b, forKey: "blinking")
        }
    }

    private func updateRecordingDuration() {
        guard let lbl = recordingIndicator.viewWithTag(996) as? UILabel else { return }
        let e = CACurrentMediaTime() - recordingStartTime
        lbl.text = String(format: "%02d:%02d:%02d",
                          Int(e) / 3600, (Int(e) % 3600) / 60, Int(e) % 60)
    }

    private func stopRecordingIndicator() {
        recordingDurationTimer?.invalidate(); recordingDurationTimer = nil
        recordingIndicator.viewWithTag(999)?.layer.removeAnimation(forKey: "blinking")
        UIView.animate(withDuration: 0.3) { self.recordingIndicator.alpha = 0 }
    }

    private func showSuccessFeedback() {
        successFeedbackView.alpha = 1
        UIView.animate(withDuration: 0.3, delay: 2.0) { self.successFeedbackView.alpha = 0 }
    }

    // MARK: - Button actions

    @objc private func livePauseTapped()       { pausePlayback() }
    @objc private func stopSessionTapped()     { stopSession() }
    @objc private func countdownStopTapped()   { stopSession() }
    @objc private func restartButtonTapped()   { restartCountdown() }

    @objc private func playPauseTapped() {
        if isLooping { stopLoop() } else { startLoop() }
    }

    @objc private func clipSaveButtonTapped() {
        if isClipMode {
            saveClipToPhotos()
        } else {
            guard isPaused else { return }
            if isLooping { stopLoop() }
            enterClipMode()
        }
    }

    // MARK: - AVPlayer setup / teardown

    /// Install the player (call once after pauseRecording returns a composition).
    private func setupPlayer(with item: AVPlayerItem, composition: AVMutableComposition) {
        tearDownPlayer()

        // ── Trim the item to the displayable window only ──
        // This means AVPlayer naturally ends at the pause point, never
        // playing into the delay buffer. No boundary observer needed.
        if let buf = videoFileBuffer {
            let endTime = buf.pausedCompositionEndTime
            if CMTimeGetSeconds(endTime) > 0 {
                item.forwardPlaybackEndTime = endTime
                print("✂️ PlayerItem forwardPlaybackEndTime: \(CMTimeGetSeconds(endTime))s " +
                      "(composition total: \(CMTimeGetSeconds(composition.duration))s)")
            }
        }

        let p = AVPlayer(playerItem: item)
        p.actionAtItemEnd = .none
        self.player = p

        let pl = AVPlayerLayer(player: p)
        pl.frame        = bounds
        pl.videoGravity = .resizeAspectFill
        if let dlIdx = layer.sublayers?.firstIndex(where: { $0 === displayImageView.layer }) {
            layer.insertSublayer(pl, at: UInt32(dlIdx + 1))
        } else {
            layer.insertSublayer(pl, at: 0)
        }
        self.playerLayer = pl
        applyPlayerLayerTransform()

        // Periodic observer — keeps scrubber in sync during playback
        let fps = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let interval = CMTime(value: 1, timescale: CMTimeScale(fps))
        playerTimeObserver = p.addPeriodicTimeObserver(
            forInterval: interval, queue: .main) { [weak self] time in
            guard let self, let buf = self.videoFileBuffer else { return }
            self.playerDidAdvance(to: time, duration: buf.pausedCompositionEndTime)
        }

        // Loop observer — fires when item reaches forwardPlaybackEndTime
        playerLoopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main) { [weak self] _ in
            guard let self, self.isLooping else { return }
            self.loopBackToStart()
        }

        print("✅ AVPlayer ready")
    }

    private func loopBackToStart() {
        guard let buf = videoFileBuffer else { return }

        let loopStartTime: CMTime
        if isClipMode {
            loopStartTime = buf.compositionTime(forFrameIndex: clipStartIndex) ?? .zero
        } else {
            // Start of the displayed scrub window, not raw composition t=0
            loopStartTime = buf.pausedCompositionDisplayStartTime
        }

        player?.seek(to: loopStartTime,
                     toleranceBefore: .zero,
                     toleranceAfter:  .zero) { [weak self] finished in
            guard let self, self.isLooping, finished else { return }
            if let item = self.player?.currentItem {
                item.forwardPlaybackEndTime = self.isClipMode
                    ? (buf.compositionTime(forFrameIndex: self.clipEndIndex)
                       ?? buf.pausedCompositionEndTime)
                    : buf.pausedCompositionEndTime
            }
            self.player?.play()
        }
    }

    private func tearDownPlayer() {
        if let obs = playerTimeObserver {
            player?.removeTimeObserver(obs)
            playerTimeObserver = nil
        }
        if let obs = playerLoopObserver {
            NotificationCenter.default.removeObserver(obs)
            playerLoopObserver = nil
        }
        if let obs = playerBoundaryObserver {
            player?.removeTimeObserver(obs)
            playerBoundaryObserver = nil
        }
        player?.pause()
        player = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        isSeeking       = false
        pendingScrubIndex = nil
    }

    /// Called by the periodic time observer during playback to advance the
    /// scrubber UI and the scrubberPosition index.
    private func playerDidAdvance(to time: CMTime, duration: CMTime) {
        guard isLooping, let buf = videoFileBuffer else { return }

        let fps        = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let totalFrames    = buf.getTimestampCount()
        let requiredFrames = delaySeconds * fps
        let pausePoint = max(0, totalFrames - requiredFrames)
        let oldest     = oldestAllowedIndex()
        let scrubRange = max(1, pausePoint - oldest)

        if isClipMode {
            // Clip mode: map composition time fraction onto clip range
            let clipRange = max(1, clipEndIndex - clipStartIndex)
            let endSecs   = CMTimeGetSeconds(
                buf.compositionTime(forFrameIndex: clipEndIndex) ?? duration)
            let startSecs = CMTimeGetSeconds(
                buf.compositionTime(forFrameIndex: clipStartIndex) ?? .zero)
            let rangeSecs = max(0.001, endSecs - startSecs)
            let fraction  = (CMTimeGetSeconds(time) - startSecs) / rangeSecs
            clipPlayheadPosition = clipStartIndex +
                min(Int(fraction * Double(clipRange)), clipRange)
            updatePlayheadPosition()
            updateTimeLabel()
        } else {
            // Scrub mode: map composition time directly onto scrubber range.
            // This avoids the frameTimestamps binary search which is unreliable
            // after pruning — the delay buffer frames sit at the start of the
            // array and cause the scrubber to stall for delaySeconds at loop start.
            let displayStart = CMTimeGetSeconds(buf.pausedCompositionDisplayStartTime)
            let displayEnd   = CMTimeGetSeconds(buf.pausedCompositionEndTime)
            let displayRange = max(0.001, displayEnd - displayStart)
            let fraction     = (CMTimeGetSeconds(time) - displayStart) / displayRange
            let clamped      = max(0.0, min(fraction, 1.0))

            scrubberPosition = oldest + Int(clamped * Double(scrubRange))
            scrubberPosition = min(scrubberPosition, pausePoint)

            updateScrubberPlayheadPosition()
            let displayPos = (scrubberPosition >= pausePoint) ? pausePoint : scrubberPosition
            let secs = Float(displayPos - oldest) / Float(fps)
            timeLabel.text = formatTime(secs)
        }
    }

    // MARK: - Seek helper (scrub + clip playhead)

    /// Seek the player to the given frame index.
    /// Calls are coalesced: if a seek is already in flight the new index is
    /// stored as `pendingScrubIndex` and fired when the current seek finishes.
    private func seekPlayer(toFrameIndex index: Int) {
        guard let buf = videoFileBuffer,
              let compositionTime = buf.compositionTime(forFrameIndex: index) else { return }

        if isSeeking {
            pendingScrubIndex = index
            return
        }

        isSeeking = true
        // Tight tolerance on both sides → nearest decoded frame.
        let fps = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let half = CMTime(value: 1, timescale: CMTimeScale(fps * 2))
        player?.seek(to: compositionTime,
                     toleranceBefore: half,
                     toleranceAfter:  half) { [weak self] _ in
            guard let self else { return }
            self.isSeeking = false
            if let next = self.pendingScrubIndex {
                self.pendingScrubIndex = nil
                self.seekPlayer(toFrameIndex: next)
            }
        }
    }

    // MARK: - Loop playback

    private func startLoop() {
        guard let buf = videoFileBuffer,
              let comp = buf.pausedComposition else { return }

        isLooping = true
        let cfg = UIImage.SymbolConfiguration(pointSize: 32, weight: .bold)
        playPauseButton.setImage(
            UIImage(systemName: "pause.fill", withConfiguration: cfg), for: .normal)

        if player == nil {
            let item = AVPlayerItem(asset: comp)
            setupPlayer(with: item, composition: comp)
        }

        let fps = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let half = CMTime(value: 1, timescale: CMTimeScale(fps * 2))

        // ── Ratio-based seek — avoids compositionTime() index/prune issues ──
        // Map scrubberPosition as a fraction of the scrub range directly onto
        // the composition duration, which is what the scrub bar visually represents.
        let startTime: CMTime
        if isClipMode {
            startTime = buf.compositionTime(forFrameIndex: clipPlayheadPosition) ?? .zero
        } else {
            let endTime     = CMTimeGetSeconds(buf.pausedCompositionEndTime)
            let totalFrames = buf.getTimestampCount()
            let requiredFrames = delaySeconds * fps
            let pausePoint  = max(0, totalFrames - requiredFrames)
            let scrubBack   = min(scrubDurationSeconds * fps, pausePoint)
            let oldest      = max(0, pausePoint - scrubBack)
            let scrubRange  = max(1, pausePoint - oldest)

            let fraction    = Double(scrubberPosition - oldest) / Double(scrubRange)
            let displayDuration = CMTimeGetSeconds(buf.pausedCompositionEndTime)
                                - CMTimeGetSeconds(buf.pausedCompositionDisplayStartTime)
            let seekSeconds = CMTimeGetSeconds(buf.pausedCompositionDisplayStartTime)
                            + (displayDuration * max(0.0, min(fraction, 1.0)))
            startTime = CMTime(seconds: seekSeconds, preferredTimescale: 600)
        }

        player?.seek(to: startTime,
                     toleranceBefore: half,
                     toleranceAfter:  half) { [weak self] _ in
            guard let self, self.isLooping else { return }
            self.player?.play()
        }

        playerLayer?.isHidden  = false
        displayImageView.alpha = 0
    }

    private func stopLoop() {
        isLooping = false
        player?.pause()

        let cfg = UIImage.SymbolConfiguration(pointSize: 32, weight: .bold)
        playPauseButton.setImage(
            UIImage(systemName: "play.circle.fill", withConfiguration: cfg), for: .normal)

        // Snap the still frame for the current position onto displayImageView,
        // then hide the player layer so scrubbing shows UIImageView frames.
        let idx = isClipMode ? clipPlayheadPosition : scrubberPosition
        seekPlayer(toFrameIndex: idx)  // keep player in sync for next play
        showStillFrameForCurrentPosition()
    }

    /// Capture a single video frame at the current scrub position and show it
    /// on displayImageView (used when not playing).
    private func showStillFrameForCurrentPosition() {
        // The player layer already shows the correct frame while paused; we
        // just make sure displayImageView is hidden so the player shows through.
        // When actually scrubbing we use seekPlayer which updates the player
        // layer live — no UIImageView decode needed.
        playerLayer?.isHidden  = false
        displayImageView.alpha = 0
    }

    // MARK: - Scrubber pan (non-clip mode)

    @objc private func handleScrubberPan(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began {
            if isLooping { stopLoop() }
        }
        
        // ── In clip mode, scrubbing the background moves the clip playhead ──
        if isClipMode {
            let location = gesture.location(in: timelineContainer)
            guard let buf = videoFileBuffer else { return }
            let actualFPS = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
            let totalFrames = buf.getTimestampCount()
            let requiredFrames = delaySeconds * actualFPS
            guard totalFrames > requiredFrames else { return }

            let pausePoint  = totalFrames - requiredFrames
            let oldest      = oldestAllowedIndex()
            let scrubRange  = pausePoint - oldest
            let timelineWidth = timelineContainer.bounds.width
            guard scrubRange > 0, timelineWidth > 0 else { return }

            let clampedX      = max(0, min(location.x, timelineWidth))
            let normalized    = clampedX / timelineWidth
            let frameIndex    = oldest + Int(normalized * CGFloat(scrubRange))

            // Clamp to clip region
            clipPlayheadPosition = min(max(frameIndex, clipStartIndex), clipEndIndex)
            seekPlayer(toFrameIndex: clipPlayheadPosition)
            updatePlayheadPosition()
            updateTimeLabel()
            return
        }

        // ── Normal scrub mode ──
        let location = gesture.location(in: timelineContainer)
        let actualFPS = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)

        guard let buf = videoFileBuffer else { return }
        let totalFrames = buf.getTimestampCount()
        let requiredFrames = delaySeconds * actualFPS
        guard totalFrames > requiredFrames else { return }

        let pausePoint   = totalFrames - requiredFrames
        let oldest       = oldestAllowedIndex()
        let scrubRange   = pausePoint - oldest
        let timelineWidth = timelineContainer.bounds.width
        guard scrubRange > 0, timelineWidth > 0 else { return }

        let clampedX        = max(0, min(location.x, timelineWidth))
        let normalizedPos   = clampedX / timelineWidth
        let frameIndex      = oldest + Int(normalizedPos * CGFloat(scrubRange))
        scrubberPosition    = max(oldest, min(frameIndex, pausePoint - 1))

        updateScrubberPlayheadPosition()

        let displayPos = (scrubberPosition >= pausePoint - 1) ? pausePoint : scrubberPosition
        let secs = Float(displayPos - oldest) / Float(actualFPS)
        timeLabel.text = formatTime(secs)

        // Seek the player (coalesced — never stacks).
        seekPlayer(toFrameIndex: scrubberPosition)
    }

    private func updateScrubberPlayheadPosition() {
        guard let buf = videoFileBuffer else { return }
        let actualFPS      = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let totalFrames    = buf.getTimestampCount()
        let requiredFrames = delaySeconds * actualFPS
        guard totalFrames > requiredFrames else { return }

        let pausePoint = totalFrames - requiredFrames
        let oldest     = oldestAllowedIndex()
        let scrubRange = pausePoint - oldest
        guard scrubRange > 0 else { return }

        let timelineWidth = timelineContainer.bounds.width
        guard timelineWidth > 0 else { return }

        let clamped    = max(oldest, min(scrubberPosition, pausePoint - 1))
        let normalized = CGFloat(clamped - oldest) / CGFloat(scrubRange)
        let playheadX  = normalized * timelineWidth

        scrubberPlayheadConstraint?.constant = playheadX
        let touchX = max(0, min(playheadX - 22, timelineWidth - 44))
        scrubberTouchAreaConstraint?.constant = touchX
        timelineContainer.layoutIfNeeded()
    }
    
    // MARK: - Pause playback (live → paused)

    private func pausePlayback() {
        guard !isPaused, isShowingDelayed else { return }

        captureSession?.stopRunning()
        isPaused = true
        displayTimer?.invalidate(); displayTimer = nil

        stopRecordingIndicator()
        hideLivePauseButton()

        let actualFPS = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        videoFileBuffer?.pauseRecording { [weak self] item, composition in
            guard let self else { return }
            guard let item, let composition else {
                print("❌ pauseRecording returned nil")
                return
            }

            let totalFrames    = self.videoFileBuffer?.getTimestampCount() ?? 0
            let requiredFrames = self.delaySeconds * actualFPS
            let pausePoint     = max(0, totalFrames - requiredFrames)
            self.scrubberPosition = max(0, pausePoint - 1)

            self.setupPlayer(with: item, composition: composition)
            
            // Show buffer limit label only if recorded longer than buffer setting
            let bufferDurationSeconds = Settings.shared.bufferDurationSeconds
            let recordedSeconds = totalFrames / actualFPS
            if recordedSeconds > bufferDurationSeconds {
                let minutes = bufferDurationSeconds / 60
                let minLabel = minutes == 1 ? "min" : "mins"
                self.bufferLimitLabel.setTitle("Playback limited to last \(minutes) \(minLabel)", for: .normal)
                self.bufferLimitLabel.alpha = 1
            } else {
                self.bufferLimitLabel.alpha = 0
            }
            
            self.seekPlayer(toFrameIndex: self.scrubberPosition)

            self.updateScrubberPlayheadPosition()
            self.showControls()
            self.playerLayer?.isHidden = false
            self.displayImageView.alpha = 0
            
            // Restore label visibility after showControls
            if !self.bufferLimitLabel.isHidden {
                self.bufferLimitLabel.alpha = 1
            }

            /*
            let oldest = self.oldestAllowedIndex()
            let secs   = Float(self.scrubberPosition - oldest) / Float(actualFPS)
            self.timeLabel.text = self.formatTime(secs)
             */
            let oldest = self.oldestAllowedIndex()
            let displaySecs = Float(pausePoint - oldest) / Float(actualFPS)
            self.timeLabel.text = self.formatTime(displaySecs)

            print("⏸ Paused — scrubberPosition: \(self.scrubberPosition), " +
                  "totalFrames: \(totalFrames), " +
                  "pausePoint: \(pausePoint), " +
                  "oldest: \(oldest)")
        }
    }

    // MARK: - Oldest allowed index helper

    private func oldestAllowedIndex() -> Int {
        guard let buf = videoFileBuffer else { return 0 }
        let actualFPS      = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let totalFrames    = buf.getTimestampCount()
        let requiredFrames = delaySeconds * actualFPS
        guard totalFrames > requiredFrames else { return 0 }
        let pausePoint = totalFrames - requiredFrames
        let scrubBack  = scrubDurationSeconds * actualFPS
        return max(0, pausePoint - scrubBack)
    }

    // MARK: - Orientation

    @objc private func orientationDidChange() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.forceOrientationUpdate()
            self?.applyPlayerLayerTransform()
        }
    }

    private func forceOrientationUpdate() {
        guard let conn = previewLayer?.connection else { return }
        let ori = UIApplication.shared.windows.first?.windowScene?.interfaceOrientation
        if isFrontCamera {
            switch ori {
            case .landscapeLeft:      conn.videoRotationAngle = 0
            case .landscapeRight:     conn.videoRotationAngle = 180
            case .portrait:           conn.videoRotationAngle = 90
            case .portraitUpsideDown: conn.videoRotationAngle = 270
            default:                  conn.videoRotationAngle = 0
            }
        } else {
            switch ori {
            case .landscapeLeft:      conn.videoRotationAngle = 180
            case .landscapeRight:     conn.videoRotationAngle = 0
            case .portrait:           conn.videoRotationAngle = 90
            case .portraitUpsideDown: conn.videoRotationAngle = 270
            default:                  conn.videoRotationAngle = 0
            }
        }
    }

    /// Match the AVPlayerLayer's transform to the current capture orientation
    /// so the paused / playing video appears correctly oriented.
    private func applyPlayerLayerTransform() {
        guard let pl = playerLayer else { return }
        let angle = previewLayer?.connection?.videoRotationAngle ?? 0
        let radians = angle * .pi / 180.0
        var t = CGAffineTransform(rotationAngle: CGFloat(radians))
        if isFrontCamera { t = t.scaledBy(x: -1, y: 1) }
        pl.setAffineTransform(t)
        pl.frame = bounds
    }

    // MARK: - Session setup

    func startSession(delaySeconds: Int, useFrontCamera: Bool) {
        self.delaySeconds  = delaySeconds
        self.isActive      = true
        self.isFrontCamera = useFrontCamera
        self.isPaused      = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.setupCamera(useFrontCamera: useFrontCamera)
        }
    }

    private func setupCamera(useFrontCamera: Bool) {
        captureSession = AVCaptureSession()
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.captureSession.beginConfiguration()
            self.captureSession.sessionPreset = .high

            let pos: AVCaptureDevice.Position = useFrontCamera ? .front : .back
            guard let camera = AVCaptureDevice.default(
                .builtInWideAngleCamera, for: .video, position: pos) else {
                print("❌ No camera found")
                self.captureSession.commitConfiguration()
                return
            }
            self.currentDevice = camera

            let actualFPS = Settings.shared.currentFPS(isFrontCamera: useFrontCamera)

            do {
                try camera.lockForConfiguration()
                var fpsSet = false
                for r in camera.activeFormat.videoSupportedFrameRateRanges {
                    if Double(actualFPS) >= r.minFrameRate &&
                       Double(actualFPS) <= r.maxFrameRate {
                        camera.activeVideoMinFrameDuration =
                            CMTime(value: 1, timescale: CMTimeScale(actualFPS))
                        camera.activeVideoMaxFrameDuration =
                            CMTime(value: 1, timescale: CMTimeScale(actualFPS))
                        fpsSet = true; break
                    }
                }
                if !fpsSet {
                    camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                    camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                    Settings.shared.setFPS(30, isFrontCamera: useFrontCamera)
                }
                camera.unlockForConfiguration()
            } catch { print("❌ Camera config error: \(error)") }

            //let maxDuration = 300 + self.delaySeconds + 10
            let maxDuration = Settings.shared.bufferDurationSeconds + self.delaySeconds + 10
            self.videoFileBuffer = VideoFileBuffer(
                maxDurationSeconds: maxDuration,
                delaySeconds:       self.delaySeconds,
                fps:                actualFPS,
                writeQueue:         self.captureQueue,
                ciContext:          self.ciContext)

            do {
                let input = try AVCaptureDeviceInput(device: camera)
                if self.captureSession.canAddInput(input) {
                    self.captureSession.addInput(input)
                } else {
                    print("❌ Cannot add input")
                    self.captureSession.commitConfiguration()
                    return
                }
            } catch {
                print("❌ Input error: \(error)")
                self.captureSession.commitConfiguration()
                return
            }

            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String:
                                    kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = false
            output.setSampleBufferDelegate(self, queue: self.captureQueue)
            if self.captureSession.canAddOutput(output) {
                self.captureSession.addOutput(output)
            }
            self.videoDataOutput = output
            self.captureSession.commitConfiguration()

            // Zoom
            do {
                try camera.lockForConfiguration()
                let saved = Settings.shared.currentZoomFactor(isFrontCamera: useFrontCamera)
                let clamped = min(max(saved, camera.minAvailableVideoZoomFactor),
                                  min(camera.activeFormat.videoMaxZoomFactor, 10.0))
                camera.videoZoomFactor = clamped
                camera.unlockForConfiguration()
            } catch {}

            let videoWidth  = 1920, videoHeight = 1080
            let videoSettings: [String: Any] = [
                AVVideoCodecKey:  AVVideoCodecType.h264,
                AVVideoWidthKey:  videoWidth,
                AVVideoHeightKey: videoHeight,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey:       videoWidth * videoHeight * 11,
                    AVVideoProfileLevelKey:         AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoExpectedSourceFrameRateKey: actualFPS,
                    AVVideoMaxKeyFrameIntervalKey:  actualFPS
                ]
            ]

            try? self.videoFileBuffer?.startWriting(
                videoSettings: videoSettings, isInitialStart: true)

            DispatchQueue.main.async {
                let preview = AVCaptureVideoPreviewLayer(session: self.captureSession)
                preview.videoGravity = .resizeAspectFill
                preview.frame        = self.bounds
                self.layer.insertSublayer(preview, at: 0)
                self.previewLayer = preview
                self.forceOrientationUpdate()

                // Bring UI layers to front.
                for v in [self.displayImageView!,
                          self.countdownLabel, self.countdownStopButton,
                          self.livePauseButton, self.successFeedbackView,
                          self.cancelClipButton, self.recordingIndicator,
                          self.controlsContainer, self.topRightButtonContainer, self.bufferLimitLabel] as [UIView] {
                    self.bringSubviewToFront(v)
                }
            }

            self.captureQueue.async {
                if !self.captureSession.isRunning { self.captureSession.startRunning() }
                DispatchQueue.main.async { self.startCountdown() }
            }
        }
    }

    // MARK: - Countdown

    private func startCountdown() {
        var countdown = delaySeconds
        countdownLabel.text  = "\(countdown)"
        countdownLabel.alpha  = 1
        countdownStopButton.alpha = 1

        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self, self.isActive else { timer.invalidate(); return }
            countdown -= 1
            if countdown <= 0 {
                timer.invalidate()
                self.countdownLabel.alpha     = 0
                self.countdownStopButton.alpha = 0
                self.startDelayedDisplay()
            } else {
                self.countdownLabel.text = "\(countdown)"
            }
        }
    }

    private func startDelayedDisplay() {
        isShowingDelayed = true

        // Show recording indicator.
        if let lbl = recordingIndicator.viewWithTag(997) as? UILabel {
            lbl.text = "-\(delaySeconds)s"
        }
        recordingStartTime = CACurrentMediaTime()
        recordingDurationTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.updateRecordingDuration()
        }
        startRecordingIndicator()

        UIView.animate(withDuration: 0.3) {
            self.displayImageView.alpha = 1
            self.previewLayer?.opacity  = 0
        }

        displayImageView.alpha = 1

        let actualFPS      = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let delayFrames    = delaySeconds * actualFPS
        let frameInterval  = 1.0 / Double(actualFPS)

        displayTimer = Timer.scheduledTimer(
            withTimeInterval: frameInterval, repeats: true) { [weak self] _ in
            guard let self, let buf = self.videoFileBuffer else { return }
            let total  = buf.getCurrentFrameCount()
            let target = total - delayFrames
            guard target >= 0 else { return }
            if let img = buf.getRecentFrame(at: target) {
                self.displayFrame(img)
            }
        }
        RunLoop.main.add(displayTimer!, forMode: .common)
        showLivePauseButton()
        startActivityCheckTimer()
    }

    // MARK: - Stop session

    func stopSession() {
        guard isActive else { return }
        isActive         = false
        isShowingDelayed = false
        isPaused         = false

        displayTimer?.invalidate(); displayTimer = nil
        stopRecordingIndicator()
        hideLivePauseButton()
        hideControls()
        tearDownPlayer()

        if isLooping { isLooping = false }
        if isClipMode { exitClipModeClean() }
        
        bufferLimitLabel.alpha = 0

        captureQueue.async { [weak self] in
            guard let self else { return }
            self.captureSession?.stopRunning()
            let old = self.videoFileBuffer
            self.videoFileBuffer = nil
            old?.cleanup()
            DispatchQueue.main.async {
                self.previewLayer?.removeFromSuperlayer()
                self.previewLayer = nil
                self.displayImageView.alpha = 0
                self.onSessionStopped?()
            }
        }
    }

    // MARK: - Restart

    private func restartCountdown() {
        // 1. Clean up playback/clip state
        if isLooping   { stopLoop() }
        if isClipMode  { exitClipModeClean() }
        hideControls()
        tearDownPlayer()
        hideActivityAlert()
        activityCheckTimer?.invalidate()
        activityCountdownTimer?.invalidate()
        stopRecordingIndicator()
        displayTimer?.invalidate()
        displayTimer = nil

        // 2. Reset all state flags
        isPaused         = false
        isShowingDelayed = false
        isActive         = false   // temporarily false while we rebuild
        scrubberPosition = 0
        clipStartIndex   = 0
        clipEndIndex     = 0
        clipPlayheadPosition = 0
        lastUpdateTime   = 0
        bufferLimitLabel.alpha = 0

        // 3. Reset duration label
        if let durationLabel = recordingIndicator.viewWithTag(996) as? UILabel {
            durationLabel.text = "00:00:00"
        }

        // 4. Fully stop the existing capture session and tear down everything,
        //    just like stopSession does — but without calling onSessionStopped.
        let savedDelay         = delaySeconds
        let savedIsFrontCamera = isFrontCamera

        captureQueue.async { [weak self] in
            guard let self else { return }

            // Stop the running session
            if self.captureSession?.isRunning == true {
                self.captureSession.stopRunning()
            }

            // Tear down the old buffer completely
            let oldBuffer    = self.videoFileBuffer
            self.videoFileBuffer = nil
            oldBuffer?.cleanup()
            print("♻️ Old capture session and buffer fully torn down")

            DispatchQueue.main.async {
                // Remove the old preview layer
                self.previewLayer?.removeFromSuperlayer()
                self.previewLayer = nil

                // Remove all inputs and outputs from the old session
                // so setupCamera gets a clean slate
                if let session = self.captureSession {
                    session.beginConfiguration()
                    session.inputs.forEach  { session.removeInput($0) }
                    session.outputs.forEach { session.removeOutput($0) }
                    session.commitConfiguration()
                }
                self.captureSession = nil
                self.videoDataOutput = nil
                self.currentDevice   = nil

                self.displayImageView.alpha = 0

                // 5. Now do a full re-init exactly like startSession does
                self.isActive      = true
                self.isFrontCamera = savedIsFrontCamera
                self.delaySeconds  = savedDelay
                self.isPaused      = false

                print("♻️ Restarting capture stack from scratch...")
                self.setupCamera(useFrontCamera: savedIsFrontCamera)
            }
        }
    }

    // MARK: - Display frame (live delay)

    private func displayFrame(_ rawImage: UIImage) {
        guard let cg = rawImage.cgImage else {
            DispatchQueue.main.async { self.displayImageView.image = rawImage }
            return
        }

        let angle = previewLayer?.connection?.videoRotationAngle ?? 0
        let ori: UIImage.Orientation
        switch angle {
        case 90:  ori = .right
        case 180: ori = .down
        case 270: ori = .left
        default:  ori = .up
        }
        let img = UIImage(cgImage: cg, scale: 1.0, orientation: ori)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.displayImageView.image     = img
            self.displayImageView.transform = self.isFrontCamera
                ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        }
    }

    // MARK: - Clip mode

    private func enterClipMode() {
        guard let buf = videoFileBuffer else { return }

        let actualFPS      = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let totalFrames    = buf.getTimestampCount()
        let requiredFrames = delaySeconds * actualFPS
        guard totalFrames > requiredFrames else { return }

        let pausePoint  = totalFrames - requiredFrames
        let oldest      = oldestAllowedIndex()
        guard pausePoint > oldest else { return }

        isClipMode           = true
        clipStartIndex       = oldest
        clipEndIndex         = pausePoint
        clipPlayheadPosition = scrubberPosition

        let cfg = UIImage.SymbolConfiguration(pointSize: 32, weight: .bold)
        clipSaveButton.setImage(
            UIImage(systemName: "arrow.down.to.line.circle.fill", withConfiguration: cfg),
            for: .normal)
        clipSaveButton.tintColor = .white

        UIView.animate(withDuration: 0.3) {
            self.scrubberBackground.alpha   = 0
            self.scrubberPlayhead.alpha     = 0
            self.clipRegionBackground.isHidden = false
            self.leftDimView.isHidden          = false
            self.rightDimView.isHidden         = false
            self.topBorder.isHidden            = false
            self.bottomBorder.isHidden         = false
            self.leftTrimHandle.isHidden       = false
            self.rightTrimHandle.isHidden      = false
            self.clipPlayhead.isHidden         = false
            self.playheadTouchArea.isHidden    = false
            self.cancelClipButton.isHidden     = false
        }

        updateClipHandlePositions()
        updatePlayheadPosition()
        updateTimeLabel()
        
        // Arm the player end time to the clip end, not the full pause point
        if let item = player?.currentItem {
            item.forwardPlaybackEndTime =
                videoFileBuffer?.compositionTime(forFrameIndex: clipEndIndex)
                ?? buf.pausedCompositionEndTime
        }
    }

    @objc private func cancelClipTapped() {
        if isLooping { stopLoop() }
        exitClipMode()
    }

    private func exitClipMode() {
        scrubberPosition = clipPlayheadPosition
        exitClipModeClean()
        seekPlayer(toFrameIndex: scrubberPosition)
        updateScrubberPlayheadPosition()
        let actualFPS = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let oldest    = oldestAllowedIndex()
        let secs      = Float(scrubberPosition - oldest) / Float(actualFPS)
        //timeLabel.text = String(format: "%05.2f", secs)
        timeLabel.text = formatTime(secs)
    }

    private func exitClipModeClean() {
        isClipMode = false
        let cfg = UIImage.SymbolConfiguration(pointSize: 32, weight: .bold)
        clipSaveButton.setImage(
            UIImage(systemName: "film.circle.fill", withConfiguration: cfg), for: .normal)
        clipSaveButton.tintColor = .white

        UIView.animate(withDuration: 0.3) {
            self.leftDimView.isHidden          = true
            self.rightDimView.isHidden         = true
            self.topBorder.isHidden            = true
            self.bottomBorder.isHidden         = true
            self.leftTrimHandle.isHidden       = true
            self.rightTrimHandle.isHidden      = true
            self.clipPlayhead.isHidden         = true
            self.playheadTouchArea.isHidden    = true
            self.clipRegionBackground.isHidden = true
            self.scrubberBackground.alpha      = 1
            self.scrubberPlayhead.alpha        = 1
            self.cancelClipButton.isHidden     = true
        }
        
        // Restore end time to full scrub window boundary
        if let item = player?.currentItem, let buf = videoFileBuffer {
            item.forwardPlaybackEndTime = buf.pausedCompositionEndTime
        }
    }

    // MARK: - Clip handle positions

    private func updateClipHandlePositions() {
        guard isClipMode, let buf = videoFileBuffer else { return }

        let actualFPS      = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let totalFrames    = buf.getTimestampCount()
        let requiredFrames = delaySeconds * actualFPS
        guard totalFrames > requiredFrames else { return }

        let pausePoint    = totalFrames - requiredFrames
        let oldest        = oldestAllowedIndex()
        let totalRange    = pausePoint - oldest
        guard totalRange > 0 else { return }

        let w = timelineContainer.bounds.width
        guard w > 0 else { return }

        let leftNorm  = CGFloat(clipStartIndex - oldest) / CGFloat(totalRange)
        let rightNorm = CGFloat(clipEndIndex   - oldest) / CGFloat(totalRange)

        leftHandleConstraint?.constant  = leftNorm * w
        rightHandleConstraint?.constant = -(w - rightNorm * w)
        timelineContainer.layoutIfNeeded()
    }

    private func updatePlayheadPosition() {
        guard isClipMode else { return }

        let w = timelineContainer.bounds.width
        guard w > 0, clipEndIndex > clipStartIndex else { return }

        guard let buf = videoFileBuffer else { return }
        let actualFPS      = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let totalFrames    = buf.getTimestampCount()
        let requiredFrames = delaySeconds * actualFPS
        guard totalFrames > requiredFrames else { return }

        let pausePoint  = totalFrames - requiredFrames
        let oldest      = oldestAllowedIndex()
        let totalRange  = pausePoint - oldest
        guard totalRange > 0 else { return }

        let leftNorm  = CGFloat(clipStartIndex - oldest) / CGFloat(totalRange)
        let rightNorm = CGFloat(clipEndIndex   - oldest) / CGFloat(totalRange)
        let leftEdge  = leftNorm  * w + handleWidth
        let rightEdge = rightNorm * w - handleWidth
        let clipWidth = rightEdge - leftEdge
        guard clipWidth > 0 else { return }

        let normPH = CGFloat(clipPlayheadPosition - clipStartIndex) /
                     CGFloat(clipEndIndex - clipStartIndex)
        let phX    = leftEdge + normPH * clipWidth

        playheadConstraint?.constant = phX
        let touchX = max(0, min(phX - 22, w - 44))
        playheadTouchArea.frame.origin.x = touchX
        timelineContainer.layoutIfNeeded()
    }

    private func updateTimeLabel() {
        guard isClipMode else { return }
        let actualFPS = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let t = Float(clipPlayheadPosition - clipStartIndex) / Float(actualFPS)
        //timeLabel.text = String(format: "%05.2f", t)
        timeLabel.text = formatTime(t)
    }

    // MARK: - Trim handle gestures

    @objc private func handleLeftTrimPan(_ gesture: UIPanGestureRecognizer) {
        let tr = gesture.translation(in: timelineContainer)

        if gesture.state == .began {
            if isLooping { stopLoop() }
            isDraggingHandle   = true
            initialLeftPosition = leftHandleConstraint?.constant ?? 0
            initialClipStartIndex = clipStartIndex
            clipPlayhead.alpha     = 0
            playheadTouchArea.alpha = 0
        }

        guard let buf = videoFileBuffer else { return }
        let actualFPS      = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let totalFrames    = buf.getTimestampCount()
        let requiredFrames = delaySeconds * actualFPS
        guard totalFrames > requiredFrames else { return }

        let pausePoint  = totalFrames - requiredFrames
        let oldest      = oldestAllowedIndex()
        let scrubRange  = pausePoint - oldest
        let w           = timelineContainer.bounds.width
        guard w > 0 else { return }

        let newLeft = initialLeftPosition + tr.x
        let norm    = max(0, min(newLeft / w, 1))
        let newStart = oldest + Int(norm * CGFloat(scrubRange))

        clipStartIndex = max(oldest, min(newStart, clipEndIndex - actualFPS))
        clipPlayheadPosition = clipStartIndex
        updateClipHandlePositions()
        updatePlayheadPosition()
        updateTimeLabel()

        if gesture.state == .changed {
            let now = CACurrentMediaTime()
            if now - lastUpdateTime > 0.05 {
                lastUpdateTime = now
                seekPlayer(toFrameIndex: clipPlayheadPosition)
            }
        }

        if gesture.state == .ended || gesture.state == .cancelled {
            isDraggingHandle = false
            seekPlayer(toFrameIndex: clipPlayheadPosition)
            UIView.animate(withDuration: 0.3) {
                self.clipPlayhead.alpha     = 1
                self.playheadTouchArea.alpha = 1
            }
        }
    }

    @objc private func handleRightTrimPan(_ gesture: UIPanGestureRecognizer) {
        let tr = gesture.translation(in: timelineContainer)

        if gesture.state == .began {
            if isLooping { stopLoop() }
            isDraggingHandle    = true
            initialRightPosition = rightHandleConstraint?.constant ?? 0
            initialClipEndIndex  = clipEndIndex
            clipPlayhead.alpha      = 0
            playheadTouchArea.alpha  = 0
        }

        guard let buf = videoFileBuffer else { return }
        let actualFPS      = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let totalFrames    = buf.getTimestampCount()
        let requiredFrames = delaySeconds * actualFPS
        guard totalFrames > requiredFrames else { return }

        let pausePoint  = totalFrames - requiredFrames
        let oldest      = oldestAllowedIndex()
        let scrubRange  = pausePoint - oldest
        let w           = timelineContainer.bounds.width
        guard w > 0 else { return }

        let currentFromLeft = w + (initialRightPosition) + tr.x
        let norm = max(0, min(currentFromLeft / w, 1))
        let newEnd = oldest + Int(norm * CGFloat(scrubRange))

        clipEndIndex = max(clipStartIndex + actualFPS, min(newEnd, pausePoint))
        clipPlayheadPosition = clipEndIndex
        updateClipHandlePositions()
        updatePlayheadPosition()
        updateTimeLabel()

        if gesture.state == .changed {
            let now = CACurrentMediaTime()
            if now - lastUpdateTime > 0.05 {
                lastUpdateTime = now
                seekPlayer(toFrameIndex: clipPlayheadPosition)
            }
        }

        if gesture.state == .ended || gesture.state == .cancelled {
            isDraggingHandle = false
            seekPlayer(toFrameIndex: clipPlayheadPosition)

            // Update player end time to match new clip end
            if let item = player?.currentItem, let buf = videoFileBuffer {
                item.forwardPlaybackEndTime =
                    buf.compositionTime(forFrameIndex: clipEndIndex)
                    ?? buf.pausedCompositionEndTime
            }

            UIView.animate(withDuration: 0.3) {
                self.clipPlayhead.alpha      = 1
                self.playheadTouchArea.alpha = 1
            }
        }
    }

    @objc private func handlePlayheadPan(_ gesture: UIPanGestureRecognizer) {
        let tr = gesture.translation(in: timelineContainer)

        if gesture.state == .began {
            if isLooping { stopLoop() }
            initialPlayheadPosition      = playheadConstraint?.constant ?? 0
            initialClipPlayheadPosition  = clipPlayheadPosition
        }

        guard clipEndIndex > clipStartIndex else { return }
        let w = timelineContainer.bounds.width
        guard w > 0 else { return }

        guard let buf = videoFileBuffer else { return }
        let actualFPS      = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let totalFrames    = buf.getTimestampCount()
        let requiredFrames = delaySeconds * actualFPS
        guard totalFrames > requiredFrames else { return }

        let pausePoint  = totalFrames - requiredFrames
        let oldest      = oldestAllowedIndex()
        let totalRange  = pausePoint - oldest
        guard totalRange > 0 else { return }

        let leftNorm  = CGFloat(clipStartIndex - oldest) / CGFloat(totalRange)
        let rightNorm = CGFloat(clipEndIndex   - oldest) / CGFloat(totalRange)
        let leftEdge  = leftNorm  * w + handleWidth
        let rightEdge = rightNorm * w - handleWidth
        let clipWidth = rightEdge - leftEdge
        guard clipWidth > 0 else { return }

        let newX      = max(leftEdge, min(initialPlayheadPosition + tr.x, rightEdge))
        let normPH    = (newX - leftEdge) / clipWidth
        let newFrame  = clipStartIndex + Int(normPH * CGFloat(clipEndIndex - clipStartIndex))
        clipPlayheadPosition = max(clipStartIndex, min(newFrame, clipEndIndex))

        updatePlayheadPosition()
        updateTimeLabel()
        seekPlayer(toFrameIndex: clipPlayheadPosition)
    }

    @objc private func handleTimelineTap(_ gesture: UITapGestureRecognizer) {
        guard isClipMode else { return }
        
        // ── In clip mode ──
        if isClipMode {
            let location = gesture.location(in: timelineContainer)
            guard let buf = videoFileBuffer else { return }
            let actualFPS = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
            let totalFrames = buf.getTimestampCount()
            let requiredFrames = delaySeconds * actualFPS
            guard totalFrames > requiredFrames else { return }

            let pausePoint    = totalFrames - requiredFrames
            let oldest        = oldestAllowedIndex()
            let scrubRange    = pausePoint - oldest
            let timelineWidth = timelineContainer.bounds.width
            guard scrubRange > 0, timelineWidth > 0 else { return }

            let clampedX   = max(0, min(location.x, timelineWidth))
            let normalized = clampedX / timelineWidth
            let frameIndex = oldest + Int(normalized * CGFloat(scrubRange))

            clipPlayheadPosition = min(max(frameIndex, clipStartIndex), clipEndIndex)
            seekPlayer(toFrameIndex: clipPlayheadPosition)
            updatePlayheadPosition()
            updateTimeLabel()
            return
        }

        // existing tap-to-scrub code for non-clip mode...
        let loc = gesture.location(in: timelineContainer)
        let w   = timelineContainer.bounds.width
        guard w > 0, clipEndIndex > clipStartIndex else { return }

        guard let buf = videoFileBuffer else { return }
        let actualFPS      = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let totalFrames    = buf.getTimestampCount()
        let requiredFrames = delaySeconds * actualFPS
        guard totalFrames > requiredFrames else { return }

        let pausePoint  = totalFrames - requiredFrames
        let oldest      = oldestAllowedIndex()
        let totalRange  = pausePoint - oldest
        guard totalRange > 0 else { return }

        let leftNorm  = CGFloat(clipStartIndex - oldest) / CGFloat(totalRange)
        let rightNorm = CGFloat(clipEndIndex   - oldest) / CGFloat(totalRange)
        let leftEdge  = leftNorm  * w + handleWidth
        let rightEdge = rightNorm * w - handleWidth
        guard loc.x >= leftEdge && loc.x <= rightEdge else { return }

        let clipWidth = rightEdge - leftEdge
        let normPH    = (loc.x - leftEdge) / clipWidth
        let newFrame  = clipStartIndex + Int(normPH * CGFloat(clipEndIndex - clipStartIndex))
        clipPlayheadPosition = max(clipStartIndex, min(newFrame, clipEndIndex))

        updatePlayheadPosition()
        updateTimeLabel()
        seekPlayer(toFrameIndex: clipPlayheadPosition)
    }

    // MARK: - Save clip to Photos

    private func saveClipToPhotos() {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard status != .denied && status != .restricted else {
            showPhotosPermissionAlert(); return
        }

        let actualFPS = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let frames    = clipEndIndex - clipStartIndex
        let secs      = frames / max(actualFPS, 1)

        if secs > 60 {
            let alert = UIAlertController(
                title:   "Long Clip",
                message: "This clip is \(secs / 60):\(String(format: "%02d", secs % 60)) long. Saving may take a moment.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Save",   style: .default) { [weak self] _ in
                self?.performSaveClip()
            })
            window?.rootViewController?.present(alert, animated: true)
            return
        }
        performSaveClip()
    }

    private func performSaveClip() {
        let loading = createLoadingView(text: "Saving to Album...")
        addSubview(loading)

        createClipVideo { [weak self] url in
            guard let self else { return }
            guard let url else {
                DispatchQueue.main.async {
                    loading.removeFromSuperview()
                    self.showError("Failed to create video clip")
                }
                return
            }
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                DispatchQueue.main.async {
                    guard status == .authorized || status == .limited else {
                        loading.removeFromSuperview()
                        self.showPhotosPermissionAlert()
                        return
                    }
                    PHPhotoLibrary.shared().performChanges({
                        PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
                    }) { success, error in
                        DispatchQueue.main.async {
                            loading.removeFromSuperview()
                            if success {
                                self.showSuccessFeedback()
                                self.exitClipMode()
                            } else {
                                self.showError("Failed to save to Album")
                            }
                        }
                    }
                }
            }
        }
    }

    private func showPhotosPermissionAlert() {
        let alert = UIAlertController(
            title:   "Photos Access Required",
            message: "Loopr needs permission to save clips to your Photos library.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
            if let u = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(u)
            }
        })
        alert.addAction(UIAlertAction(title: "Not Now", style: .cancel))
        window?.rootViewController?.present(alert, animated: true)
    }

    // MARK: - Clip export

    private func createClipVideo(completion: @escaping (URL?) -> Void) {
        guard let videoFileBuffer,
              let composition = videoFileBuffer.pausedComposition else {
            print("❌ createClipVideo: no composition available")
            completion(nil)
            return
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("swingclip_\(Int(Date().timeIntervalSince1970)).mp4")
        try? FileManager.default.removeItem(at: outputURL)

        let actualFPS     = Settings.shared.currentFPS(isFrontCamera: isFrontCamera)
        let rotationAngle = previewLayer?.connection?.videoRotationAngle ?? 0

        // Determine natural render size from the composition track itself.
        // This respects whatever resolution was actually recorded.
        let naturalSize: CGSize
        if let track = composition.tracks(withMediaType: .video).first {
            let size = track.naturalSize
            // If the track itself is already rotated (portrait), size.width < size.height.
            naturalSize = size
        } else {
            naturalSize = CGSize(width: 1920, height: 1080)
        }

        // Output size: portrait recordings need width/height swapped so the
        // exported file is upright without relying on a metadata transform.
        let isPortrait = rotationAngle == 90 || rotationAngle == 270
        let renderSize = isPortrait
            ? CGSize(width: naturalSize.height, height: naturalSize.width)
            : naturalSize

        print("📐 Export renderSize: \(renderSize), rotationAngle: \(rotationAngle), " +
              "isFrontCamera: \(isFrontCamera)")

        // Choose a preset compatible with the composition.
        // Prefer passthrough (no re-encode) but fall back to quality presets.
        let candidatePresets = AVAssetExportSession.exportPresets(compatibleWith: composition)
        print("📦 Compatible presets: \(candidatePresets)")

        // For clips we always re-encode so the rotation bake-in works correctly.
        // Pick the highest quality preset that's compatible.
        let preferredPresets = [
            AVAssetExportPreset1920x1080,
            AVAssetExportPreset1280x720,
            AVAssetExportPresetHighestQuality,
            AVAssetExportPresetMediumQuality
        ]
        let chosenPreset = preferredPresets.first { candidatePresets.contains($0) }
                           ?? AVAssetExportPresetMediumQuality

        print("📦 Using export preset: \(chosenPreset)")

        guard let exporter = AVAssetExportSession(
            asset: composition, presetName: chosenPreset) else {
            print("❌ Could not create AVAssetExportSession")
            completion(nil)
            return
        }

        exporter.outputURL      = outputURL
        exporter.outputFileType = .mp4

        // Clip time range within the composition.
        let startTime = videoFileBuffer.compositionTime(forFrameIndex: clipStartIndex) ?? .zero
        let endTime   = videoFileBuffer.compositionTime(forFrameIndex: clipEndIndex)
                        ?? composition.duration
        exporter.timeRange = CMTimeRange(start: startTime, end: endTime)

        // Build the video composition to bake in orientation + front-camera mirror.
        // The instruction must cover the FULL composition duration (not just the clip
        // range) — the exporter's timeRange property handles the actual trim.
        guard let compVideoTrack = composition.tracks(withMediaType: .video).first else {
            print("❌ No video track in composition")
            completion(nil)
            return
        }

        let videoComposition          = AVMutableVideoComposition()
        videoComposition.renderSize   = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(actualFPS))

        let instruction       = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, end: composition.duration)

        let layerInstruction  = AVMutableVideoCompositionLayerInstruction(
            assetTrack: compVideoTrack)

        // Build the affine transform to rotate and optionally mirror.
        // We bake rotation into the pixel data so the file is self-contained
        // (no hidden metadata transform that some players ignore).
        var transform = CGAffineTransform.identity

        switch rotationAngle {
        case 90:
            // Rotate 90° CW: (x,y) → (y, -x), translate back into positive quadrant.
            transform = CGAffineTransform(rotationAngle: .pi / 2)
                .translatedBy(x: 0, y: -naturalSize.width)
        case 180:
            transform = CGAffineTransform(rotationAngle: .pi)
                .translatedBy(x: -naturalSize.width, y: -naturalSize.height)
        case 270:
            // Rotate 90° CCW.
            transform = CGAffineTransform(rotationAngle: -.pi / 2)
                .translatedBy(x: -naturalSize.height, y: 0)
        default:
            transform = .identity
        }

        if isFrontCamera {
            // Mirror horizontally in the rotated coordinate space.
            // After rotation the render frame is renderSize wide, so we flip
            // on the vertical axis (negate x, translate by renderWidth).
            let mirror = CGAffineTransform(scaleX: -1, y: 1)
                .translatedBy(x: -renderSize.width, y: 0)
            transform = transform.concatenating(mirror)
        }

        layerInstruction.setTransform(transform, at: .zero)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions  = [instruction]

        exporter.videoComposition = videoComposition

        print("⏳ Starting export: clipStart=\(CMTimeGetSeconds(startTime))s, " +
              "clipEnd=\(CMTimeGetSeconds(endTime))s, " +
              "duration=\(CMTimeGetSeconds(endTime - startTime))s")

        exporter.exportAsynchronously {
            DispatchQueue.main.async {
                switch exporter.status {
                case .completed:
                    print("✅ Export completed: \(outputURL.lastPathComponent)")
                    completion(outputURL)
                case .failed:
                    print("❌ Export failed: \(exporter.error?.localizedDescription ?? "unknown")")
                    print("❌ Export error detail: \(exporter.error.debugDescription)")
                    completion(nil)
                case .cancelled:
                    print("⚠️ Export cancelled")
                    completion(nil)
                default:
                    print("⚠️ Export unexpected status: \(exporter.status.rawValue)")
                    completion(nil)
                }
            }
        }
    }

    // MARK: - Loading view / error helpers

    private func createLoadingView(text: String) -> UIView {
        let container = UIView()
        container.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        container.layer.cornerRadius = 20
        container.clipsToBounds = true
        container.translatesAutoresizingMaskIntoConstraints = false

        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = .white
        spinner.startAnimating()
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let label = UILabel()
        label.text = text
        label.textColor = .white
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(spinner)
        container.addSubview(label)
        addSubview(container)

        NSLayoutConstraint.activate([
            container.centerXAnchor.constraint(equalTo: centerXAnchor),
            container.centerYAnchor.constraint(equalTo: centerYAnchor),
            container.widthAnchor.constraint(equalToConstant: 200),
            container.heightAnchor.constraint(equalToConstant: 120),
            spinner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            label.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12)
        ])

        return container
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: "Error", message: message,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        window?.rootViewController?.present(alert, animated: true)
    }

    // MARK: - Activity check

    private func startActivityCheckTimer() {
        activityCheckTimer?.invalidate()
        activityCheckTimer = Timer.scheduledTimer(
            withTimeInterval: activityCheckInterval,
            repeats: false) { [weak self] _ in
            self?.showActivityAlert()
        }
    }

    private func restartActivityCheckTimer() {
        activityCheckTimer?.invalidate()
        activityCountdownTimer?.invalidate()
        hideActivityAlert()
        startActivityCheckTimer()
    }

    private func showActivityAlert() {
        activityTimeRemaining = 60
        updateActivityProgress(animated: false)

        UIView.animate(withDuration: 0.3) {
            self.activityAlertContainer.alpha = 1
        }

        activityCountdownTimer?.invalidate()
        activityCountdownTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.activityTimeRemaining -= 1
            self.updateActivityProgress(animated: true)
            if self.activityTimeRemaining <= 0 {
                self.activityCountdownTimer?.invalidate()
                self.pausePlayback()
                self.hideActivityAlert()
            }
        }
    }

    private func hideActivityAlert() {
        UIView.animate(withDuration: 0.3) {
            self.activityAlertContainer.alpha = 0
        }
    }

    private func updateActivityProgress(animated: Bool) {
        guard let yesButton = activityAlertContainer.viewWithTag(1001),
              let overlay   = activityAlertContainer.viewWithTag(1002) else { return }

        let fraction = CGFloat(activityTimeRemaining) / 60.0
        let newWidth  = yesButton.bounds.width * fraction

        if animated {
            UIView.animate(withDuration: 0.9, delay: 0,
                           options: .curveLinear) {
                self.activityProgressConstraint?.constant = newWidth
                overlay.layoutIfNeeded()
            }
        } else {
            activityProgressConstraint?.constant = newWidth
            overlay.layoutIfNeeded()
        }
    }

    @objc private func activityYesTapped() {
        activityCountdownTimer?.invalidate()
        hideActivityAlert()
        restartActivityCheckTimer()
    }

    @objc private func activityNoTapped() {
        activityCountdownTimer?.invalidate()
        hideActivityAlert()
        pausePlayback()
    }

    @objc private func activityBackgroundTapped(_ gesture: UITapGestureRecognizer) {
        // Taps on the container itself (not buttons) do nothing — prevents
        // accidental dismissal. Intentionally empty.
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension DelayedCameraView: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard isActive, !isPaused, let buf = videoFileBuffer else { return }
        buf.appendFrame(sampleBuffer: sampleBuffer) { _ in }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // Dropped frames during heavy load — acceptable at startup.
    }
}

// MARK: - UIGestureRecognizerDelegate

extension DelayedCameraView: UIGestureRecognizerDelegate {
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        return false
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
        return false
    }
}
