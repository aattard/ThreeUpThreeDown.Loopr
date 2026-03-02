import Foundation
import AVFoundation
import Photos
import UIKit

enum VideoExportError: LocalizedError {
    case missingBuffer
    case permissionDenied
    case exportFailed
    case saveFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .missingBuffer: return "Video buffer or composition is missing."
        case .permissionDenied: return "Photos permission is required to save clips."
        case .exportFailed: return "Could not create the video clip."
        case .saveFailed(let msg): return "Failed to save to Photos: \(msg)"
        }
    }
}

final class VideoExportManager {
    
    /// Exports the specified frame range to a temporary file and saves it to the user's Photo Library.
    static func exportAndSaveClip(
        from buffer: VideoFileBuffer,
        startIndex: Int,
        endIndex: Int,
        isFrontCamera: Bool,
        rotationAngle: CGFloat,
        fps: Int,
        completion: @escaping (Result<Void, VideoExportError>) -> Void
    ) {
        // 1. Check Photos permission first
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard status != .denied && status != .restricted else {
            completion(.failure(.permissionDenied))
            return
        }
        
        // 2. Export the video
        createClipVideo(from: buffer, startIndex: startIndex, endIndex: endIndex, isFrontCamera: isFrontCamera, rotationAngle: rotationAngle, fps: fps) { url in
            guard let url = url else {
                completion(.failure(.exportFailed))
                return
            }
            
            // 3. Save to Photo Library
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { success, error in
                // Always clean up the temporary file
                try? FileManager.default.removeItem(at: url)
                
                DispatchQueue.main.async {
                    if success {
                        completion(.success(()))
                    } else {
                        completion(.failure(.saveFailed(error?.localizedDescription ?? "Unknown error")))
                    }
                }
            }
        }
    }
    
    private static func createClipVideo(
        from buffer: VideoFileBuffer,
        startIndex: Int,
        endIndex: Int,
        isFrontCamera: Bool,
        rotationAngle: CGFloat,
        fps: Int,
        completion: @escaping (URL?) -> Void
    ) {
        guard let comp = buffer.pausedComposition else {
            completion(nil)
            return
        }

        // 1. Calculate duration strictly from the frames selected to avoid Out-Of-Bounds index lookups
        let actualFPS = max(fps, 1)
        let frames = max(0, endIndex - startIndex)
        let durationSeconds = Double(frames) / Double(actualFPS)
        let duration = CMTime(seconds: durationSeconds, preferredTimescale: 600)
        
        // 2. Look up the start time (this is safe because startIndex is always within bounds)
        let startTime = buffer.compositionTime(forFrameIndex: startIndex) ?? .zero
        let timeRange = CMTimeRange(start: startTime, duration: duration)

        let tmp = FileManager.default.temporaryDirectory
        let url = tmp.appendingPathComponent("LooprClip-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: url)

        guard let exporter = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            completion(nil)
            return
        }
        
        exporter.outputURL = url
        exporter.outputFileType = .mp4
        exporter.timeRange = timeRange
        exporter.shouldOptimizeForNetworkUse = true

        // Enforce orientation/mirroring
        if let videoTrack = comp.tracks(withMediaType: .video).first {
            let natural = videoTrack.naturalSize
            let transform = VideoPlaybackHelpers.exportTransformForRotationAngle(rotationAngle, naturalSize: natural, isFrontCamera: isFrontCamera)

            let vc = AVMutableVideoComposition()
            vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(actualFPS))

            // Render size: rotate swaps width/height.
            let renderSize: CGSize
            if Int(rotationAngle) == 90 || Int(rotationAngle) == 270 {
                renderSize = CGSize(width: natural.height, height: natural.width)
            } else {
                renderSize = natural
            }
            vc.renderSize = CGSize(width: abs(renderSize.width), height: abs(renderSize.height))

            let instruction = AVMutableVideoCompositionInstruction()
            // Ensure the instruction covers the entire composition so the exporter can extract the timeRange
            instruction.timeRange = CMTimeRange(start: .zero, duration: comp.duration)

            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            layerInstruction.setTransform(transform, at: .zero)

            instruction.layerInstructions = [layerInstruction]
            vc.instructions = [instruction]

            // ── Watermark + timestamp overlay ────────────────────────────────────
            if let animTool = makeWatermarkAnimationTool(canvasSize: vc.renderSize) {
                vc.animationTool = animTool
            }

            exporter.videoComposition = vc
        }

        exporter.exportAsynchronously {
            DispatchQueue.main.async {
                if exporter.status == .completed {
                    completion(url)
                } else {
                    print("Export failed: \(exporter.error?.localizedDescription ?? "Unknown")")
                    completion(nil)
                }
            }
        }
    }

    // MARK: - Watermark

    /// Burns "watermark-logo" from Assets into the top-right corner and a date/time
    /// stamp into the bottom-left corner of every frame.
    private static func makeWatermarkAnimationTool(canvasSize: CGSize) -> AVVideoCompositionCoreAnimationTool? {
        guard let image = UIImage(named: "watermark-logo") else {
            print("⚠️ VideoExport: watermark-logo image not found in asset catalog")
            return nil
        }
        print("✅ VideoExport: watermark-logo loaded, canvas=\(canvasSize.width)x\(canvasSize.height)")

        let shortSide = min(canvasSize.width, canvasSize.height)
        let markSize  = round(shortSide * 0.12)
        let inset     = round(shortSide * 0.02)

        let videoLayer = CALayer()
        videoLayer.frame = CGRect(origin: .zero, size: canvasSize)

        let parentLayer = CALayer()
        parentLayer.frame = CGRect(origin: .zero, size: canvasSize)
        parentLayer.addSublayer(videoLayer)

        // ── Logo mark (top-right) ─────────────────────────────────────────────
        let markLayer = CALayer()
        markLayer.contents        = image.cgImage
        markLayer.contentsGravity = .resizeAspect
        markLayer.opacity         = 0.5
        markLayer.frame = CGRect(
            x: canvasSize.width  - markSize - inset,
            y: inset,
            width:  markSize,
            height: markSize
        )
        parentLayer.addSublayer(markLayer)

        // ── Date/time stamp (bottom-left) ─────────────────────────────────────
        let tsLayer = makeTimestampLayer(date: Date(), canvasSize: canvasSize)
        parentLayer.addSublayer(tsLayer)

        return AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )
    }

    // MARK: - Timestamp Layer

    /// Creates a CATextLayer showing the current date/time as "MM/DD/YYYY HH:MM:SS TZ"
    /// (e.g. "03/02/2026 13:56:00 EST") styled to match the recording indicator pill
    /// in DelayedCameraView — same font (monospacedDigitSystemFont, light), same pill
    /// proportions. Font size is fixed small so the watermark stays unobtrusive when
    /// burned into a 1080p/1920p canvas.
    ///
    /// - Important: AVFoundation composites CALayer trees with a **bottom-up** y-axis
    ///   (origin at bottom-left), so a layer at `y = inset` sits `inset` pixels above
    ///   the bottom edge of the canvas — which is visually the bottom-left corner.
    static func makeTimestampLayer(date: Date, canvasSize: CGSize) -> CALayer {

        // ── Format the timestamp ──────────────────────────────────────────────
        // Format date and time separately so we control the separator (space,
        // not the locale-injected comma that combined dateStyle+timeStyle produces).
        let datePart = DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .none)
        let timePart = DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)

        let offsetSeconds = TimeZone.current.secondsFromGMT(for: date)
        let offsetHours   = offsetSeconds / 3600
        let offsetMins    = abs((offsetSeconds % 3600) / 60)
        let offsetLabel   = offsetMins == 0
            ? String(format: "GMT%+d", offsetHours)
            : String(format: "GMT%+d:%02d", offsetHours, offsetMins)

        let timestampString = "\(datePart) \(timePart) \(offsetLabel)"
        // → "3/2/2026 2:37 PM GMT-5"

        // ── Sizing ────────────────────────────────────────────────────────────
        let fontSize: CGFloat     = 22
        let pillH: CGFloat        = 36
        let cornerRadius: CGFloat = 18
        let hInset: CGFloat       = 12
        let canvasInset: CGFloat  = 20
        let maxPillW: CGFloat     = canvasSize.width - (canvasInset * 2)

        // ── Measure text width ────────────────────────────────────────────────
        let uiFont  = UIFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .light)
        let ctFont  = uiFont as CTFont

        let attrs: [NSAttributedString.Key: Any] = [.font: uiFont]
        let attrString = NSAttributedString(string: timestampString, attributes: attrs)
        let framesetter = CTFramesetterCreateWithAttributedString(attrString)
        let textSize = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRangeMake(0, attrString.length),
            nil,
            CGSize(width: CGFloat.greatestFiniteMagnitude, height: pillH),
            nil
        )
        let textWidth        = ceil(textSize.width)
        let pillW            = min(textWidth + hInset * 2, maxPillW)
        let clampedTextWidth = pillW - hInset * 2

        // ── Background pill ───────────────────────────────────────────────────
        let bgLayer             = CALayer()
        bgLayer.frame           = CGRect(x: canvasInset, y: canvasInset, width: pillW, height: pillH)
        bgLayer.backgroundColor = UIColor.black.withAlphaComponent(0.45).cgColor
        bgLayer.cornerRadius    = cornerRadius
        bgLayer.masksToBounds   = true

        // ── Text layer ────────────────────────────────────────────────────────
        let ascender   = CTFontGetAscent(ctFont)
        let descender  = CTFontGetDescent(ctFont)
        let leading    = CTFontGetLeading(ctFont)
        let lineHeight = ceil(ascender + descender + leading)
        let textY      = round((pillH - lineHeight) / 2.0)

        let textLayer             = CATextLayer()
        textLayer.frame           = CGRect(x: hInset, y: textY, width: clampedTextWidth, height: lineHeight)
        textLayer.font            = ctFont
        textLayer.fontSize        = fontSize
        textLayer.string          = timestampString
        textLayer.foregroundColor = UIColor.white.cgColor
        textLayer.alignmentMode   = .left
        textLayer.contentsScale   = 1.0
        textLayer.isWrapped       = false
        textLayer.truncationMode  = .end

        bgLayer.addSublayer(textLayer)
        return bgLayer
    }


}
