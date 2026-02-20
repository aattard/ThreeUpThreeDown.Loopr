import UIKit
import AVFoundation

enum VideoPlaybackHelpers {

    static func formatTime(_ seconds: Float) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        let frac = Int((seconds - Float(Int(seconds))) * 100)
        return String(format: "%02d:%02d.%02d", mins, secs, frac)
    }

    static func imageOrientation(forRotationAngle angle: CGFloat) -> UIImage.Orientation {
        switch Int(angle) {
        case 90:  return .right
        case 180: return .down
        case 270: return .left
        default:  return .up
        }
    }

    static func playerLayerTransform(rotationAngle angle: CGFloat, isFrontCamera: Bool) -> CGAffineTransform {
        let radians = angle * .pi / 180.0
        var t = CGAffineTransform(rotationAngle: radians)
        if isFrontCamera { t = t.scaledBy(x: -1, y: 1) }
        return t
    }

    /// A conservative transform for export when the underlying asset doesn’t carry a correct preferredTransform.
    /// If your VideoFileBuffer already writes correct transforms, the exporter will still work fine with this.
    static func exportTransformForRotationAngle(_ angle: CGFloat, naturalSize: CGSize, isFrontCamera: Bool) -> CGAffineTransform {
        let w = naturalSize.width
        let h = naturalSize.height

        let base: CGAffineTransform
        let renderWidth: CGFloat // We need to know the final width to mirror correctly

        switch Int(angle) {
        case 90:
            base = CGAffineTransform(translationX: h, y: 0).rotated(by: .pi / 2)
            renderWidth = h
        case 180:
            base = CGAffineTransform(translationX: w, y: h).rotated(by: .pi)
            renderWidth = w
        case 270:
            base = CGAffineTransform(translationX: 0, y: w).rotated(by: -.pi / 2)
            renderWidth = h
        default:
            base = .identity
            renderWidth = w
        }

        if !isFrontCamera { return base }

        // To mirror horizontally without moving it off-screen:
        // 1. Scale X by -1 (which flips it to negative X space)
        // 2. Translate X by the width of the bounding box to pull it back into view.
        let mirror = CGAffineTransform(translationX: renderWidth, y: 0).scaledBy(x: -1, y: 1)
        return base.concatenating(mirror)
    }
}

