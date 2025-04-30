// The Swift Programming Language
// https://docs.swift.org/swift-book
//

import Foundation
@preconcurrency import AVFoundation
#if os(iOS)

public class AudioProcessorLibrary {
    
    public enum AudioProcessingError: Error {
        case fileNotFound
        case bufferCreationFailed
        case renderingFailed
        case unknownError
        case readerCreationFailed
        case noAudioTrackFound
        case writerCreationFailed
        case conversionFailed
        case exportSessionCreationFailed
    }
    
    public init() {}
    
    @discardableResult
    public func processAudio(
        fileURL: URL,
        volume: Float = 1.0,
        bass: Float = 0.0,
        outputDirectory: URL? = nil,
        outputName: String? = nil
    ) async throws -> URL {
        
        let saveDirectory = outputDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        
        let fileName = outputName ?? "\(fileURL.deletingPathExtension().lastPathComponent)_Processed"
        
        let cafURL = try await convertToCAF(fileURL: fileURL)
        print("CAF url is - \(cafURL)")
        let processedURL = try await applyAudioEffects(
            fileURL: cafURL,
            volume: volume,
            bass: bass,
            outputDirectory: saveDirectory,
            outputName: fileName
        )
        
        return processedURL
    }
    
    private func convertToCAF(fileURL: URL) async throws -> URL {
        print("Start converting")

        let documentDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let outputURL = documentDirectory.appendingPathComponent("\(fileURL.deletingPathExtension().lastPathComponent).caf")

        try? FileManager.default.removeItem(at: outputURL)

        let asset = AVAsset(url: fileURL)
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw AudioProcessingError.noAudioTrackFound
        }

        guard let reader = try? AVAssetReader(asset: asset) else {
            throw AudioProcessingError.readerCreationFailed
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let readerOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        reader.add(readerOutput)

        guard let writer = try? AVAssetWriter(url: outputURL, fileType: .caf) else {
            throw AudioProcessingError.writerCreationFailed
        }

        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
        writer.add(writerInput)

        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        return try await withCheckedThrowingContinuation { continuation in
            let queue = DispatchQueue(label: "audioConverterQueue")
            writerInput.requestMediaDataWhenReady(on: queue) {
                while writerInput.isReadyForMoreMediaData {
                    if let sample = readerOutput.copyNextSampleBuffer() {
                        writerInput.append(sample)
                    } else {
                        writerInput.markAsFinished()
                        writer.finishWriting {
                            if writer.status == .completed {
                                continuation.resume(returning: outputURL)
                            } else {
                                let error = writer.error ?? AudioProcessingError.writerCreationFailed
                                continuation.resume(throwing: error)
                            }
                        }
                        break
                    }
                }
            }
        }
    }
    
    private func applyAudioEffects(
        fileURL: URL,
        volume: Float,
        bass: Float,
        outputDirectory: URL,
        outputName: String
    ) async throws -> URL {
        let outputURL = outputDirectory.appendingPathComponent("\(outputName).caf")
        print("Start FX boost")
        try? FileManager.default.removeItem(at: outputURL)
        
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let equalizer = AVAudioUnitEQ(numberOfBands: 1)
        let mixer = AVAudioMixerNode()
        
        let source = try AVAudioFile(forReading: fileURL)
        
        engine.attach(player)
        engine.attach(equalizer)
        engine.attach(mixer)
        
        mixer.outputVolume = volumeBoostConverter(volume)
        
        let bassBand = equalizer.bands[0]
        bassBand.filterType = .lowShelf
        bassBand.frequency = 130.0
        bassBand.gain = bassBoostConverter(bass)
        bassBand.bypass = false
        
        engine.connect(player, to: equalizer, format: source.processingFormat)
        engine.connect(equalizer, to: mixer, format: source.processingFormat)
        engine.connect(mixer, to: engine.mainMixerNode, format: source.processingFormat)
        
        player.scheduleFile(source, at: nil, completionHandler: {
            print("Playback completed")
        })
        
        try engine.enableManualRenderingMode(
            .offline,
            format: source.processingFormat,
            maximumFrameCount: 4096
        )
        
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat,
            frameCapacity: engine.manualRenderingMaximumFrameCount
        ) else {
            throw AudioProcessingError.bufferCreationFailed
        }
        
        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: source.fileFormat.settings
        )
        
        try engine.start()
        player.play()
        
        let totalFrames = AVAudioFrameCount(source.length)
        var renderedFrames: AVAudioFrameCount = 0

        while renderedFrames < totalFrames {
            let framesToRender = min(totalFrames - renderedFrames, buffer.frameCapacity)
            let status = try engine.renderOffline(framesToRender, to: buffer)

            switch status {
            case .success:
                try outputFile.write(from: buffer)
                renderedFrames += framesToRender
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                continue
            case .error:
                throw AudioProcessingError.renderingFailed
            @unknown default:
                throw AudioProcessingError.unknownError
            }
        }
        
        player.stop()
        engine.stop()
        
        return outputURL
    }
    
    private func bassBoostConverter(_ value: Float) -> Float {
        switch value {
        case 0: return -10.0
        case 0.00000001...99.999999999: return (value * 0.01)
        default: return (value * 0.01 - 1)
        }
    }
    
    private func volumeBoostConverter(_ value: Float) -> Float {
        switch value {
        case 0...99.999999999: return (value * 0.01)
        default: return (value * 0.01 - 1)
        }
    }
}
#endif
