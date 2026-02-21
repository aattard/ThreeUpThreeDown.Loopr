import UIKit

// MARK: - FrameDial
// A continuous horizontal dial that steps through video frames one at a time.
// Visually mimics a tape measure wrapped around a cylinder — ticks scroll
// past a fixed centre point as the user drags left or right.
//
// Usage:
//   let dial = FrameDial()
//   dial.onFrameStep = { [weak self] delta in   // delta is always +1 or -1
//       self?.stepFrame(by: delta)
//   }
//   // After every seek, keep the dial informed so it knows the boundaries:
//   dial.currentFrame = newFrame
//   dial.totalFrames  = total

final class FrameDial: UIView {

    // MARK: - Public API

    /// Called with +1 (forward) or -1 (backward) on each frame step.
    var onFrameStep: ((Int) -> Void)?

    /// Called at the start of each drag so the parent can resync internal position tracking.
    var onDragBegan: (() -> Void)?

    /// Parent must update this after every seek so the dial knows boundaries.
    var currentFrame: Int = 0 {
        didSet { atStart = (currentFrame <= 0); atEnd = (currentFrame >= totalFrames - 1) }
    }
    var totalFrames: Int = 0 {
        didSet { atEnd = (currentFrame >= totalFrames - 1) }
    }

    // MARK: - Layout constants
    private let pointsPerFrame: CGFloat = 10   // px of drag = 1 frame
    private let minorTickHeightRatio: CGFloat = 0.30
    private let majorTickHeightRatio: CGFloat = 0.65
    private let tickEvery: Int = 5             // major tick every N frames
    private let tickColor   = UIColor.white.withAlphaComponent(0.35)
    private let tickColorAt = UIColor.systemRed.withAlphaComponent(0.85)
    private let bounceDistance: CGFloat = 7

    // MARK: - State
    private var dragAccumulator: CGFloat = 0   // sub-frame drag remainder
    private var atStart = false
    private var atEnd   = false

    // Boundary flash/bounce state
    private var isBouncing = false
    private var tickTintOverride: UIColor? = nil  // nil = normal colour

    // Offset driving the visual scroll of ticks (in points, wraps mod pointsPerFrame)
    private var visualOffset: CGFloat = 0

    // Haptics
    private let lightImpact  = UIImpactFeedbackGenerator(style: .light)
    private let mediumImpact = UIImpactFeedbackGenerator(style: .medium)
    private let heavyImpact  = UIImpactFeedbackGenerator(style: .heavy)

    // MARK: - Init
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        clipsToBounds = true

        lightImpact.prepare()
        mediumImpact.prepare()
        heavyImpact.prepare()

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Drawing
    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        let w = rect.width
        let h = rect.height
        let midY = h / 2
        let minorH = h * minorTickHeightRatio
        let majorH = h * majorTickHeightRatio
        let lineW: CGFloat = 1.5

        // How many ticks fit across the dial (add generous padding so ticks
        // extend edge-to-edge even when partially scrolled)
        let totalTicks = Int(w / pointsPerFrame) + 4
        let startOffset = visualOffset.truncatingRemainder(dividingBy: pointsPerFrame)

        ctx.setLineWidth(lineW)
        ctx.setLineCap(.round)

        let color = tickTintOverride ?? tickColor
        color.setStroke()

        for i in 0...totalTicks {
            let x = startOffset + CGFloat(i) * pointsPerFrame

            // 2. Subtract the visual offset's frame equivalent.
            // This ensures that as the physical lines move right, their assigned frame numbers don't jump backward.
            let absFrame = i - Int(visualOffset / pointsPerFrame)
            let isMajor = (absFrame % tickEvery == 0)

            let tickH = isMajor ? majorH : minorH
            let y0 = midY - tickH / 2
            let y1 = midY + tickH / 2

            ctx.move(to: CGPoint(x: x, y: y0))
            ctx.addLine(to: CGPoint(x: x, y: y1))
        }
        ctx.strokePath()

        // Centre indicator — slightly brighter vertical line
        ctx.setLineWidth(2)
        UIColor.white.withAlphaComponent(0.7).setStroke()
        ctx.move(to: CGPoint(x: w / 2, y: 0))
        ctx.addLine(to: CGPoint(x: w / 2, y: h))
        ctx.strokePath()
    }

    // MARK: - Pan handler
    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            dragAccumulator = 0
            onDragBegan?()   // let parent resync tracked position before first step
            lightImpact.prepare()
            mediumImpact.prepare()
            heavyImpact.prepare()

        case .changed:
            let dx = gesture.translation(in: self).x
            gesture.setTranslation(.zero, in: self)

            // Drag right = forward in time (matches scrub bar direction)
            let goingForward = dx > 0

            // Boundary: already at edge and dragging further into it
            if (goingForward && atEnd) || (!goingForward && atStart) {
                triggerBoundaryFeedback(atEnd: goingForward)
                return
            }

            dragAccumulator += dx
            // Consume full-frame increments
            while dragAccumulator >= pointsPerFrame {
                dragAccumulator -= pointsPerFrame
                step(delta: +1)
            }
            while dragAccumulator <= -pointsPerFrame {
                dragAccumulator += pointsPerFrame
                step(delta: -1)
            }

        case .ended, .cancelled:
            dragAccumulator = 0

        default:
            break
        }
    }

    // MARK: - Step one frame
    private func step(delta: Int) {
        let newFrame = currentFrame + delta
        guard newFrame >= 0 && newFrame < totalFrames else {
            triggerBoundaryFeedback(atEnd: delta > 0)
            return
        }

        // Scroll ticks visually — positive delta = forward = ticks scroll left
        visualOffset += CGFloat(delta) * pointsPerFrame
        setNeedsDisplay()

        // Haptics: medium on major ticks, light otherwise
        let isMajor = (newFrame % tickEvery == 0)
        if isMajor {
            mediumImpact.impactOccurred()
            mediumImpact.prepare()
        } else {
            lightImpact.impactOccurred()
            lightImpact.prepare()
        }

        onFrameStep?(delta)
    }

    // MARK: - Boundary feedback
    private func triggerBoundaryFeedback(atEnd: Bool) {
        guard !isBouncing else { return }
        isBouncing = true

        heavyImpact.impactOccurred()

        // Flash ticks red
        tickTintOverride = tickColorAt
        setNeedsDisplay()

        // Bounce: nudge ticks slightly in the blocked direction then spring back
        let nudge: CGFloat = atEnd ? bounceDistance : -bounceDistance
        UIView.animate(
            withDuration: 0.10,
            delay: 0,
            options: .curveEaseOut,
            animations: { self.visualOffset += nudge; self.setNeedsDisplay() },
            completion: { _ in
                UIView.animate(
                    withDuration: 0.20,
                    delay: 0,
                    usingSpringWithDamping: 0.4,
                    initialSpringVelocity: 6,
                    options: .curveEaseIn,
                    animations: { self.visualOffset -= nudge; self.setNeedsDisplay() },
                    completion: { _ in
                        self.tickTintOverride = nil
                        self.setNeedsDisplay()
                        self.isBouncing = false
                    }
                )
            }
        )
    }
}
