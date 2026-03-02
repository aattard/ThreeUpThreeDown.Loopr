import AVFoundation
import Photos
import UIKit

// MARK: - Export Configuration

struct SplitExportConfig {
    let leftURL: URL
    let rightURL: URL
    let leftTimeRange: CMTimeRange      // absolute time range in the left asset
    let rightTimeRange: CMTimeRange     // absolute time range in the right asset
    let leftZoom: CGFloat               // user's pinch scale for left pane
    let leftOffset: CGPoint             // user's pan offset for left pane (in view points)
    let rightZoom: CGFloat
    let rightOffset: CGPoint
    let leftViewSize: CGSize            // rendered size of the left pane on screen (points)
    let rightViewSize: CGSize           // rendered size of the right pane on screen (points)
    let isLandscape: Bool               // determines output orientation
}

// MARK: - Export Errors

enum SplitExportError: LocalizedError {
    case permissionDenied
    case couldNotLoadAssets
    case compositionFailed
    case exportFailed(String)
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:       return "Photos permission is required to save the clip."
        case .couldNotLoadAssets:     return "Could not load one or both video assets."
        case .compositionFailed:      return "Could not build the split-screen composition."
        case .exportFailed(let msg):  return "Export failed: \(msg)"
        case .saveFailed(let msg):    return "Could not save to Photos: \(msg)"
        }
    }
}

// MARK: - Progress Token

final class SplitExportToken {
    fileprivate(set) var exporter: AVAssetExportSession?
    private(set) var isCancelled = false

    func cancel() {
        isCancelled = true
        exporter?.cancelExport()
    }
}

// MARK: - Manager

final class SplitVideoExportManager {

    @discardableResult
    static func export(
        config: SplitExportConfig,
        progress: @escaping (Float) -> Void,
        completion: @escaping (Result<Void, SplitExportError>) -> Void
    ) -> SplitExportToken {

        let token = SplitExportToken()

        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        guard status != .denied && status != .restricted else {
            completion(.failure(.permissionDenied))
            return token
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let (composition, videoComposition) = try Self.buildComposition(config: config)
                if token.isCancelled { return }
                Self.runExport(
                    composition: composition,
                    videoComposition: videoComposition,
                    config: config,
                    token: token,
                    progress: progress,
                    completion: completion
                )
            } catch let error as SplitExportError {
                DispatchQueue.main.async { completion(.failure(error)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(.compositionFailed)) }
            }
        }

        return token
    }

    // MARK: - Composition Building

    private static func buildComposition(config: SplitExportConfig) throws -> (AVMutableComposition, AVMutableVideoComposition) {

        let leftAsset  = AVURLAsset(url: config.leftURL)
        let rightAsset = AVURLAsset(url: config.rightURL)

        guard let leftSource  = leftAsset.tracks(withMediaType: .video).first,
              let rightSource = rightAsset.tracks(withMediaType: .video).first else {
            throw SplitExportError.couldNotLoadAssets
        }

        let composition = AVMutableComposition()

        guard let leftTrack  = composition.addMutableTrack(withMediaType: .video,
                                                            preferredTrackID: kCMPersistentTrackID_Invalid),
              let rightTrack = composition.addMutableTrack(withMediaType: .video,
                                                            preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw SplitExportError.compositionFailed
        }

        let duration = config.leftTimeRange.duration
        try leftTrack.insertTimeRange(config.leftTimeRange,   of: leftSource,  at: .zero)
        try rightTrack.insertTimeRange(config.rightTimeRange, of: rightSource, at: .zero)

        // ── Output canvas ─────────────────────────────────────────────────────
        // Landscape: 1920×1080   Portrait: 1080×1920
        let outputSize: CGSize = config.isLandscape
            ? CGSize(width: 1920, height: 1080)
            : CGSize(width: 1080, height: 1920)

        let dividerPx: CGFloat = 1.0
        let halfCanvas: CGSize = config.isLandscape
            ? CGSize(width: (outputSize.width - dividerPx) / 2, height: outputSize.height)
            : CGSize(width: outputSize.width, height: (outputSize.height - dividerPx) / 2)

        let rightOrigin: CGPoint = config.isLandscape
            ? CGPoint(x: halfCanvas.width + dividerPx, y: 0)
            : CGPoint(x: 0, y: halfCanvas.height + dividerPx)

        // ── Transforms ───────────────────────────────────────────────────────
        let leftTransform = paneTransform(
            sourceTrack: leftSource,
            viewSize:    config.leftViewSize,
            paneSize:    halfCanvas,
            paneOrigin:  .zero,
            zoom:        config.leftZoom,
            offset:      config.leftOffset,
            label:       "LEFT"
        )

        let rightTransform = paneTransform(
            sourceTrack: rightSource,
            viewSize:    config.rightViewSize,
            paneSize:    halfCanvas,
            paneOrigin:  rightOrigin,
            zoom:        config.rightZoom,
            offset:      config.rightOffset,
            label:       "RIGHT"
        )

        // ── Layer instructions with source-space crop rects ───────────────────
        // setCropRectangle clips in PRE-TRANSFORM source pixel space.
        // We compute the visible window in source pixels that corresponds to
        // exactly the pane's canvas region, so zoomed content is hard-clipped
        // at the pane boundary without bleeding into the adjacent pane.
        //
        // The transform maps source pixel (x,y) → canvas pixel (a*x+c*y+tx, b*x+d*y+ty).
        // We invert that to find which source rectangle maps to the canvas pane rect.

        let leftLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: leftTrack)
        leftLayer.setTransform(leftTransform, at: .zero)
        if let leftCrop = sourceCropRect(for: leftTransform,
                                          canvasRect: CGRect(origin: .zero, size: halfCanvas),
                                          rawSize: leftSource.naturalSize) {
            leftLayer.setCropRectangle(leftCrop, at: .zero)
        }

        let rightLayer = AVMutableVideoCompositionLayerInstruction(assetTrack: rightTrack)
        rightLayer.setTransform(rightTransform, at: .zero)
        if let rightCrop = sourceCropRect(for: rightTransform,
                                           canvasRect: CGRect(origin: rightOrigin, size: halfCanvas),
                                           rawSize: rightSource.naturalSize) {
            rightLayer.setCropRectangle(rightCrop, at: .zero)
        }

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [leftLayer, rightLayer]

        let vc = AVMutableVideoComposition()
        vc.frameDuration = CMTime(value: 1, timescale: 30)
        vc.renderSize    = outputSize
        vc.instructions  = [instruction]

        // ── Watermark + timestamp overlay ─────────────────────────────────────
        if let animTool = makeWatermarkAnimationTool(canvasSize: outputSize) {
            vc.animationTool = animTool
        }

        return (composition, vc)
    }

    // MARK: - Watermark

    /// Burns "watermark-logo" from Assets into the top-right corner and a date/time
    /// stamp into the bottom-left corner of every frame.
    private static func makeWatermarkAnimationTool(canvasSize: CGSize) -> AVVideoCompositionCoreAnimationTool? {
        guard let image = UIImage(named: "watermark-logo") else {
            print("⚠️ SplitExport: watermark-logo image not found in asset catalog")
            return nil
        }
        print("✅ SplitExport: watermark-logo loaded, canvas=\(canvasSize.width)x\(canvasSize.height)")

        let shortSide = min(canvasSize.width, canvasSize.height)
        let markSize  = round(shortSide * 0.12)   // ~65px on 1080p short side
        let inset     = round(shortSide * 0.02)   // ~22px from each edge

        // AVFoundation composites sublayers of parentLayer onto each video frame.
        // Do NOT set isGeometryFlipped — AVFoundation handles coordinate orientation
        // internally. The y-axis here runs bottom→top, so bottom-right corner is:
        //   x = canvasWidth  - markSize - inset
        //   y = inset   (i.e. inset from the bottom edge)

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
        let tsLayer = VideoExportManager.makeTimestampLayer(date: Date(), canvasSize: canvasSize)
        parentLayer.addSublayer(tsLayer)

        return AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: videoLayer,
            in: parentLayer
        )
    }

    // MARK: - Source-space crop rect
    //
    // setCropRectangle clips in PRE-TRANSFORM (source pixel) space.
    // Given the canvas pane rect we want to show, we invert the layer transform
    // to find the corresponding rectangle in source pixel coordinates.
    // This is what actually clips zoomed content at the pane boundary.
    //
    // Our transforms are always: rotation (no shear) + uniform scale + translation.
    // The inverse is: translate(-tx,-ty) → scale(1/s) → inverse-rotation.
    // For the four iPhone rotation cases the inverse rotation is its transpose.

    private static func sourceCropRect(for transform: CGAffineTransform,
                                        canvasRect: CGRect,
                                        rawSize: CGSize) -> CGRect? {
        // Uniform scale is encoded in |a| for 0°/180°, or |b| for 90°/270°.
        let s: CGFloat
        if transform.b == 0 {
            s = abs(transform.a)
        } else {
            s = abs(transform.b)
        }
        guard s > 0 else { return nil }

        // Invert: canvas point → source point.
        // canvas = source * T  →  source = canvas * T.inverted()
        // Check determinant first — if zero the transform is not invertible.
        let det = transform.a * transform.d - transform.b * transform.c
        guard abs(det) > 1e-6 else { return nil }
        let inv = transform.inverted()

        // Map all four canvas corners of the pane rect into source space.
        let corners: [CGPoint] = [
            CGPoint(x: canvasRect.minX, y: canvasRect.minY),
            CGPoint(x: canvasRect.maxX, y: canvasRect.minY),
            CGPoint(x: canvasRect.minX, y: canvasRect.maxY),
            CGPoint(x: canvasRect.maxX, y: canvasRect.maxY)
        ].map { $0.applying(inv) }

        let minX = corners.map(\.x).min()!
        let minY = corners.map(\.y).min()!
        let maxX = corners.map(\.x).max()!
        let maxY = corners.map(\.y).max()!

        // Clamp to raw frame bounds so we don't request pixels that don't exist.
        let clampedMinX = max(0, minX)
        let clampedMinY = max(0, minY)
        let clampedMaxX = min(rawSize.width,  maxX)
        let clampedMaxY = min(rawSize.height, maxY)

        guard clampedMaxX > clampedMinX && clampedMaxY > clampedMinY else { return nil }

        return CGRect(x: clampedMinX, y: clampedMinY,
                      width:  clampedMaxX - clampedMinX,
                      height: clampedMaxY - clampedMinY)
    }

    // MARK: - Transform Math
    //
    // The central challenge: AVMutableVideoCompositionLayerInstruction transforms
    // operate in RAW SENSOR PIXEL SPACE. AVPlayerLayer automatically applies
    // preferredTransform during playback — layer instructions do not.
    //
    // preferredTransform is a MIXED value: it contains both a rotation (a,b,c,d)
    // AND a translation (tx,ty) expressed in RAW pixel magnitudes. For example,
    // a portrait 1920×1080 video has preferredTransform.ty = 1920.
    //
    // THE BUG with naive approaches: if you start with prefT and concatenate
    // scale(fitScale) on top, the raw-pixel translation (ty=1920) does NOT scale
    // down — it stays at 1920px and throws the video almost entirely off-canvas.
    //
    // THE FIX: strip the translation out of prefT to get rotation-only, then
    // find where the rotated frame's corners land and re-origin them at (0,0).
    // This gives a clean upright frame in a consistent coordinate space from
    // which all remaining math (fit, letterbox, zoom, pan, canvas) is reliable.

    private static func paneTransform(
        sourceTrack: AVAssetTrack,
        viewSize:    CGSize,
        paneSize:    CGSize,
        paneOrigin:  CGPoint,
        zoom:        CGFloat,
        offset:      CGPoint,
        label:       String = "pane"
    ) -> CGAffineTransform {

        let rawSize = sourceTrack.naturalSize
        let prefT   = sourceTrack.preferredTransform

        // ── Determine upright dimensions ──────────────────────────────────────
        // For a 90°/270° rotated track, width and height are swapped.
        let rotated90or270 = abs(prefT.b) > 0.5
        let uprightSize = rotated90or270
            ? CGSize(width: rawSize.height, height: rawSize.width)
            : CGSize(width: rawSize.width,  height: rawSize.height)

        // ── Aspect-fit scale: upright frame → pane ────────────────────────────
        let fitScale = min(paneSize.width  / uprightSize.width,
                           paneSize.height / uprightSize.height)

        let fittedW = uprightSize.width  * fitScale
        let fittedH = uprightSize.height * fitScale

        // ── Letterbox / pillarbox offset to centre in pane ────────────────────
        let lbX = (paneSize.width  - fittedW) / 2
        let lbY = (paneSize.height - fittedH) / 2

        // ── User zoom + pan ───────────────────────────────────────────────────
        // Convert pan from view-point space to pane-pixel space.
        let ptoPx = paneSize.width  / max(viewSize.width,  1)
        let ptoPy = paneSize.height / max(viewSize.height, 1)
        let panPx = offset.x * ptoPx
        let panPy = offset.y * ptoPy

        // Effective fit scale with user zoom applied
        let effectiveScale = fitScale * zoom

        // With zoom, the fitted frame grows. Recompute its centred origin
        // (zoom is always around the pane centre).
        let zoomedW = fittedW * zoom
        let zoomedH = fittedH * zoom
        let zoomedOriginX = (paneSize.width  - zoomedW) / 2 + panPx
        let zoomedOriginY = (paneSize.height - zoomedH) / 2 + panPy

        // ── Build the final matrix from scratch ───────────────────────────────
        //
        // AVFoundation layer transforms map: raw-pixel-point → canvas-pixel-point.
        //
        // For each rotation case we know exactly where the raw frame's axes go,
        // so we can write the matrix components directly.
        //
        // General form for a combined rotate+uniform-scale+translate:
        //   [a  b  0]   [cos  -sin  0]         [tx]
        //   [c  d  0] = [sin   cos  0] * scale, [ty]
        //   [tx ty 1]
        //
        // For the four iPhone rotation cases the rotation matrix simplifies:
        //
        //   0°   (identity):  a= s, b= 0, c= 0, d= s
        //   90°  (b=1,c=-1):  a= 0, b= s, c=-s, d= 0
        //   180° (a=-1,d=-1): a=-s, b= 0, c= 0, d=-s
        //   270° (b=-1,c=1):  a= 0, b=-s, c= s, d= 0
        //
        // tx/ty are then set so that (0,0) in the upright scaled frame
        // maps to (zoomedOriginX + paneOrigin.x, zoomedOriginY + paneOrigin.y).
        //
        // We derive tx/ty by asking: where does the raw-frame origin (0,0) end up
        // after rotation+scale, and what translation do we need to move it to
        // our desired canvas position?

        let s = effectiveScale
        let destX = zoomedOriginX + paneOrigin.x
        let destY = zoomedOriginY + paneOrigin.y

        // For each rotation case we want the top-left corner of the fitted upright
        // frame to land at (destX, destY) in canvas space.
        //
        // The transform maps raw pixel (x,y) → (a*x + c*y + tx,  b*x + d*y + ty).
        // The "top-left of upright frame" is a different raw corner for each rotation:
        //
        //   0°:   top-left upright = raw (0,    0   ) → need (destX,         destY)
        //   90°:  top-left upright = raw (0,    rawH) → need (destX,         destY)
        //   180°: top-left upright = raw (rawW, rawH) → need (destX,         destY)
        //   270°: top-left upright = raw (rawW, 0   ) → need (destX,         destY)
        //
        // Solving (a*x + c*y + tx = destX,  b*x + d*y + ty = destY) for tx,ty:

        let rawW = rawSize.width
        let rawH = rawSize.height
        let finalT: CGAffineTransform

        if prefT.b == 0 {
            if prefT.a > 0 {
                // 0°: a=s b=0 c=0 d=s — raw(0,0) is top-left
                // tx = destX,  ty = destY
                finalT = CGAffineTransform(a:  s, b:  0, c:  0, d:  s,
                                           tx: destX,
                                           ty: destY)
            } else {
                // 180°: a=-s b=0 c=0 d=-s — raw(rawW,rawH) is top-left
                // -s*rawW + tx = destX  →  tx = destX + s*rawW
                // -s*rawH + ty = destY  →  ty = destY + s*rawH
                finalT = CGAffineTransform(a: -s, b:  0, c:  0, d: -s,
                                           tx: destX + s * rawW,
                                           ty: destY + s * rawH)
            }
        } else {
            if prefT.b > 0 {
                // 90°: a=0 b=s c=-s d=0 — raw(0,rawH) is top-left
                // c*rawH + tx = destX  →  -s*rawH + tx = destX  →  tx = destX + s*rawH
                // b*0   + ty = destY  →  ty = destY
                finalT = CGAffineTransform(a:  0, b:  s, c: -s, d:  0,
                                           tx: destX + s * rawH,
                                           ty: destY)
            } else {
                // 270°: a=0 b=-s c=s d=0 — raw(rawW,0) is top-left
                // c*0   + tx = destX  →  tx = destX
                // b*rawW + ty = destY  →  -s*rawW + ty = destY  →  ty = destY + s*rawW
                finalT = CGAffineTransform(a:  0, b: -s, c:  s, d:  0,
                                           tx: destX,
                                           ty: destY + s * rawW)
            }
        }

        // ── Diagnostic logging ────────────────────────────────────────────────
        let cropForLog = sourceCropRect(for: finalT,
                                         canvasRect: CGRect(origin: paneOrigin, size: paneSize),
                                         rawSize: rawSize)
        print("""
        ╔══ SplitExport [\(label)] ══════════════════════════════════
        ║  rawSize:        \(rawSize.width) × \(rawSize.height)
        ║  prefT:          a=\(prefT.a) b=\(prefT.b) c=\(prefT.c) d=\(prefT.d) tx=\(prefT.tx) ty=\(prefT.ty)
        ║  rotated90/270:  \(rotated90or270)
        ║  uprightSize:    \(uprightSize.width) × \(uprightSize.height)
        ║  paneSize:       \(paneSize.width) × \(paneSize.height)
        ║  paneOrigin:     \(paneOrigin.x) , \(paneOrigin.y)
        ║  fitScale:       \(fitScale)
        ║  fittedW/H:      \(fittedW) × \(fittedH)
        ║  lbX/lbY:        \(lbX) / \(lbY)
        ║  viewSize:       \(viewSize.width) × \(viewSize.height)
        ║  zoom:           \(zoom)
        ║  effectiveScale: \(effectiveScale)
        ║  zoomedOriginX/Y:\(zoomedOriginX) / \(zoomedOriginY)
        ║  offset (pts):   \(offset.x) , \(offset.y)
        ║  panPx/Py:       \(panPx) / \(panPy)
        ║  destX/Y:        \(destX) / \(destY)
        ║  finalT:         a=\(finalT.a) b=\(finalT.b) c=\(finalT.c) d=\(finalT.d) tx=\(finalT.tx) ty=\(finalT.ty)
        ║  sourceCropRect: \(cropForLog.map { "\($0.origin.x),\($0.origin.y) \($0.width)×\($0.height)" } ?? "nil")
        ╚══════════════════════════════════════════════════════════
        """)

        return finalT
    }

    // MARK: - Export Session

    private static func runExport(
        composition:      AVMutableComposition,
        videoComposition: AVMutableVideoComposition,
        config:           SplitExportConfig,
        token:            SplitExportToken,
        progress:         @escaping (Float) -> Void,
        completion:       @escaping (Result<Void, SplitExportError>) -> Void
    ) {
        let tmp = FileManager.default.temporaryDirectory
        let url = tmp.appendingPathComponent("SplitExport-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: url)

        guard let exporter = AVAssetExportSession(asset: composition,
                                                   presetName: AVAssetExportPresetHighestQuality) else {
            DispatchQueue.main.async { completion(.failure(.compositionFailed)) }
            return
        }

        exporter.outputURL                   = url
        exporter.outputFileType              = .mp4
        exporter.shouldOptimizeForNetworkUse = true
        exporter.videoComposition            = videoComposition

        token.exporter = exporter

        let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { t in
            let p = exporter.progress
            DispatchQueue.main.async { progress(p) }
            if p >= 1.0 { t.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)

        exporter.exportAsynchronously {
            timer.invalidate()
            DispatchQueue.main.async { progress(1.0) }
            guard !token.isCancelled else { return }

            switch exporter.status {
            case .completed:
                Self.saveToPhotos(url: url, completion: completion)
            default:
                try? FileManager.default.removeItem(at: url)
                let msg = exporter.error?.localizedDescription ?? "Unknown error"
                DispatchQueue.main.async { completion(.failure(.exportFailed(msg))) }
            }
        }
    }

    // MARK: - Photo Library Save

    private static func saveToPhotos(url: URL,
                                      completion: @escaping (Result<Void, SplitExportError>) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                try? FileManager.default.removeItem(at: url)
                DispatchQueue.main.async { completion(.failure(.permissionDenied)) }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { success, error in
                try? FileManager.default.removeItem(at: url)
                DispatchQueue.main.async {
                    if success {
                        completion(.success(()))
                    } else {
                        let msg = error?.localizedDescription ?? "Unknown error"
                        completion(.failure(.saveFailed(msg)))
                    }
                }
            }
        }
    }
}
