import Foundation
import AVFoundation
import Photos

final class SplitTempClipExportManager {

    /// Exports the specified frame range to a temporary file and returns the URL.
    /// Caller owns cleanup (delete the file when done).
    static func exportTempClip(
        from buffer: VideoFileBuffer,
        startIndex: Int,
        endIndex: Int,
        isFrontCamera: Bool,
        rotationAngle: CGFloat,
        fps: Int,
        completion: @escaping (Result<URL, SplitTempClipExportError>) -> Void
    ) {
        guard let comp = buffer.pausedComposition else {
            completion(.failure(.missingComposition))
            return
        }

        let actualFPS = max(fps, 1)
        let frames = max(0, endIndex - startIndex)
        guard frames > 0 else {
            completion(.failure(.exportFailed("Clip range is empty.")))
            return
        }

        let durationSeconds = Double(frames) / Double(actualFPS)
        let duration = CMTime(seconds: durationSeconds, preferredTimescale: 600)

        let startTime = buffer.compositionTime(forFrameIndex: startIndex) ?? .zero
        let timeRange = CMTimeRange(start: startTime, duration: duration)

        let tmp = FileManager.default.temporaryDirectory
        let url = tmp.appendingPathComponent("LooprSplitTmp-\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: url)

        guard let exporter = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            completion(.failure(.exporterCreationFailed))
            return
        }

        exporter.outputURL = url
        exporter.outputFileType = .mp4
        exporter.timeRange = timeRange
        exporter.shouldOptimizeForNetworkUse = true

        // Enforce orientation/mirroring (match VideoExportManager behavior)
        if let videoTrack = comp.tracks(withMediaType: .video).first {
            let natural = videoTrack.naturalSize
            let transform = VideoPlaybackHelpers.exportTransformForRotationAngle(
                rotationAngle,
                naturalSize: natural,
                isFrontCamera: isFrontCamera
            )

            let vc = AVMutableVideoComposition()
            vc.frameDuration = CMTime(value: 1, timescale: CMTimeScale(actualFPS))

            let renderSize: CGSize
            if Int(rotationAngle) == 90 || Int(rotationAngle) == 270 {
                renderSize = CGSize(width: natural.height, height: natural.width)
            } else {
                renderSize = natural
            }

            vc.renderSize = CGSize(width: abs(renderSize.width), height: abs(renderSize.height))

            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: comp.duration)

            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
            layerInstruction.setTransform(transform, at: .zero)

            instruction.layerInstructions = [layerInstruction]
            vc.instructions = [instruction]

            exporter.videoComposition = vc
        }

        exporter.exportAsynchronously {
            DispatchQueue.main.async {
                if exporter.status == .completed {
                    print("✅ SplitTempClipExportManager: Created temp clip at \(url.path)")
                    completion(.success(url))
                } else {
                    let msg = exporter.error?.localizedDescription ?? "Unknown"
                    print("❌ SplitTempClipExportManager export failed: \(msg)")
                    completion(.failure(.exportFailed(msg)))
                }
            }
        }

    }
}
