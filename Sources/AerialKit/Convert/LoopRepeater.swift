import AVFoundation
import Foundation

/// Repeats an encoded unit N times by copying its compressed samples with shifted times.
/// No re-encoding. The output is one flat track with no edit list.
public enum LoopRepeater {
    public static func repeatUnit(_ unit: URL, times: Int, unitDuration: CMTime, to output: URL,
                                  filename: String, progress: (Double) -> Void) async throws {
        try? FileManager.default.removeItem(at: output)
        let probe = AVURLAsset(url: unit)
        guard let probeTrack = try await probe.loadTracks(withMediaType: .video).first else {
            throw LoopError.conversionFailed(filename: filename, detail: "unit has no video")
        }
        let formats = try await probeTrack.load(.formatDescriptions)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: formats.first)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw LoopError.conversionFailed(filename: filename, detail: "repeat input") }
        writer.add(input)
        guard writer.startWriting() else { throw LoopError.conversionFailed(filename: filename, detail: writer.error?.localizedDescription ?? "start") }
        writer.startSession(atSourceTime: .zero)

        do {
            for i in 0..<times {
                let asset = AVURLAsset(url: unit)
                guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw LoopError.conversionFailed(filename: filename, detail: "unit") }
                let reader = try AVAssetReader(asset: asset)
                let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                out.alwaysCopiesSampleData = false
                reader.add(out)
                guard reader.startReading() else { throw LoopError.conversionFailed(filename: filename, detail: reader.error?.localizedDescription ?? "read") }
                let offset = CMTimeMultiply(unitDuration, multiplier: Int32(i))
                while let sample = out.copyNextSampleBuffer() {
                    if Task.isCancelled { reader.cancelReading(); throw LoopError.cancelled }
                    guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
                    let shifted = try shift(sample, by: offset)
                    while !input.isReadyForMoreMediaData {
                        if Task.isCancelled { throw LoopError.cancelled }
                        if writer.status == .failed { throw LoopError.conversionFailed(filename: filename, detail: writer.error?.localizedDescription ?? "writer") }
                        try? await Task.sleep(nanoseconds: 1_000_000)
                    }
                    guard input.append(shifted) else {
                        throw LoopError.conversionFailed(filename: filename, detail: writer.error?.localizedDescription ?? "append")
                    }
                }
                if reader.status == .failed { throw LoopError.conversionFailed(filename: filename, detail: reader.error?.localizedDescription ?? "read") }
                progress(Double(i + 1) / Double(times))
            }
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTimeMultiply(unitDuration, multiplier: Int32(times)))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw LoopError.conversionFailed(filename: filename, detail: writer.error?.localizedDescription ?? "finish")
        }
    }

    static func shift(_ sample: CMSampleBuffer, by offset: CMTime) throws -> CMSampleBuffer {
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count)
        for i in timings.indices {
            if timings[i].presentationTimeStamp.isValid { timings[i].presentationTimeStamp = CMTimeAdd(timings[i].presentationTimeStamp, offset) }
            if timings[i].decodeTimeStamp.isValid { timings[i].decodeTimeStamp = CMTimeAdd(timings[i].decodeTimeStamp, offset) }
        }
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: count,
                                                           sampleTimingArray: &timings, sampleBufferOut: &copy)
        guard status == noErr, let copy else { throw LoopError.conversionFailed(filename: "", detail: "timing \(status)") }
        return copy
    }
}
