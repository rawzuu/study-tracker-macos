import AVFoundation
import Core

/// Přehrávání šumu a zvonků (AVAudioEngine). Engine běží jen, když něco hraje – mimo blok
/// je zastavený, takže zvukové vlákno nespotřebovává CPU.
@MainActor
final class AudioOutput {
    private let engine = AVAudioEngine()
    private let noisePlayer = AVAudioPlayerNode()
    private let chimePlayer = AVAudioPlayerNode()
    private let format: AVAudioFormat
    private var noiseBuffers: [NoiseType: AVAudioPCMBuffer] = [:]
    private var chimeBuffers: [SoundSynth.Chime: AVAudioPCMBuffer] = [:]
    private var ramp: Task<Void, Never>?
    private var chimeDone: Task<Void, Never>?

    /// Hrající šum (`off` = ticho).
    private(set) var noise: NoiseType = .off

    /// - Parameter offline: bez zvukového zařízení (testy čtou výstup přes `render`).
    init(offline: Bool = false) {
        format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        if offline {
            try? engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
        }
        engine.attach(noisePlayer)
        engine.attach(chimePlayer)
        engine.connect(noisePlayer, to: engine.mainMixerNode, format: format)
        engine.connect(chimePlayer, to: engine.mainMixerNode, format: format)
    }

    var isRunning: Bool { engine.isRunning }

    /// Spustí šum (náběh 1,5 s) nebo jen změní hlasitost, když už hraje stejný.
    func playNoise(_ type: NoiseType, volume: Double) {
        guard type != .off else { return stopNoise() }
        let target = Float(max(0, min(1, volume)) * 0.5)
        if type == noise {
            fade(to: target, over: 0.15)
            return
        }
        guard start() else { return }
        noisePlayer.stop()
        noisePlayer.volume = 0
        noisePlayer.scheduleBuffer(noiseBuffer(type), at: nil, options: .loops)
        noisePlayer.play()
        noise = type
        fade(to: target, over: 1.5)
    }

    /// Ztlumí a zastaví šum; pak zastaví engine, pokud nehraje zvonek.
    func stopNoise(fade seconds: Double = 0.8) {
        guard noise != .off else { return }
        noise = .off
        fade(to: 0, over: seconds) { [weak self] in
            self?.noisePlayer.stop()
            self?.stopIfIdle()
        }
    }

    func chime(_ kind: SoundSynth.Chime, volume: Double) {
        guard volume > 0, start() else { return }
        let buffer = chimeBuffer(kind)
        chimePlayer.volume = Float(min(1, volume))
        chimePlayer.scheduleBuffer(buffer, at: nil, options: .interrupts)
        chimePlayer.play()
        let seconds = Double(buffer.frameLength) / format.sampleRate + 0.2
        chimeDone?.cancel()
        chimeDone = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            chimeDone = nil
            chimePlayer.stop()
            stopIfIdle()
        }
    }

    /// Jen pro testy v režimu bez zařízení: vykreslí `frames` vzorků výstupu.
    func render(frames: AVAudioFrameCount) throws -> [Float] {
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: frames)!
        _ = try engine.renderOffline(frames, to: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    // MARK: - Interní

    private func start() -> Bool {
        if engine.isRunning { return true }
        do {
            try engine.start()
            return true
        } catch {
            return false // bez zvukového výstupu se nic nehraje, časovač běží dál
        }
    }

    private func stopIfIdle() {
        guard noise == .off, chimeDone == nil, engine.isRunning else { return }
        engine.stop()
    }

    /// Plynulá změna hlasitosti šumu (pár kroků za sekundu, jen během přechodu).
    private func fade(to target: Float, over seconds: Double, then done: (@MainActor () -> Void)? = nil) {
        ramp?.cancel()
        let from = noisePlayer.volume
        let steps = max(1, Int(seconds * 20))
        ramp = Task { [weak self] in
            for step in 1...steps {
                try? await Task.sleep(for: .seconds(seconds / Double(steps)))
                guard !Task.isCancelled, let self else { return }
                noisePlayer.volume = from + (target - from) * Float(step) / Float(steps)
            }
            done?()
        }
    }

    private func noiseBuffer(_ type: NoiseType) -> AVAudioPCMBuffer {
        if let cached = noiseBuffers[type] { return cached }
        var rng = SystemRandomNumberGenerator()
        let buffer = pcm(SoundSynth.noise(type, sampleRate: format.sampleRate, using: &rng))
        noiseBuffers[type] = buffer
        return buffer
    }

    private func chimeBuffer(_ kind: SoundSynth.Chime) -> AVAudioPCMBuffer {
        if let cached = chimeBuffers[kind] { return cached }
        let buffer = pcm(SoundSynth.chime(kind, sampleRate: format.sampleRate))
        chimeBuffers[kind] = buffer
        return buffer
    }

    private func pcm(_ samples: [Float]) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }
}
