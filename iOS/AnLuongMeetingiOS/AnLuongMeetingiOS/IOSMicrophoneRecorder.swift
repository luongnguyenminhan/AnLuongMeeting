import AVFoundation

final class IOSMicrophoneRecorder {
    private let engine = AVAudioEngine()
    private let inputNode: AVAudioInputNode
    private var writer: IOSAudioFileWriter?
    var onLevel: ((Float) -> Void)?

    init() {
        inputNode = engine.inputNode
    }

    func start(writer: IOSAudioFileWriter) throws {
        let format = inputNode.outputFormat(forBus: 0)
        try writer.start(format: format)
        self.writer = writer
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak self] buffer, _ in
            do { try writer.append(buffer) } catch { }
            let level = Self.peak(of: buffer)
            self?.onLevel?(level)
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        inputNode.removeTap(onBus: 0)
        engine.stop()
        writer = nil
    }

    private static func peak(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var peak: Float = 0
        for index in 0..<count { peak = max(peak, abs(channel[index])) }
        return min(max(peak, 0), 1)
    }
}
