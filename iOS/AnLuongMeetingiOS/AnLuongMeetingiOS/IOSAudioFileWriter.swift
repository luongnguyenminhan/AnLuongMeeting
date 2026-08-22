import AVFoundation

final class IOSAudioFileWriter {
    private let outputURL: URL
    private var audioFile: AVAudioFile?
    private let lock = NSLock()

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func start(format: AVAudioFormat) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000
        ]
        audioFile = try AVAudioFile(
            forWriting: outputURL,
            settings: settings,
            commonFormat: .pcmFormatInt16,
            interleaved: false
        )
    }

    func append(_ buffer: AVAudioPCMBuffer) throws {
        lock.lock()
        defer { lock.unlock() }
        try audioFile?.write(from: buffer)
    }

    func finish() -> URL {
        lock.lock()
        audioFile = nil
        lock.unlock()
        return outputURL
    }
}
