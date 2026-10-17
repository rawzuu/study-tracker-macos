import Core
import Foundation

/// Šum a zvonky generované přímo v aplikaci, žádné zvukové soubory (`noise.ts` a `alerts.ts` na webu).
public enum SoundSynth {
    public enum Chime: Sendable, CaseIterable {
        /// Konec bloku práce: stoupající tóny.
        case workEnd
        /// Konec pauzy.
        case breakEnd

        var notes: [Double] {
            switch self {
            case .workEnd: [659.25, 783.99, 1046.5]
            case .breakEnd: [523.25, 659.25, 523.25]
            }
        }
    }

    static let loopSeconds = 12.0
    static let crossfadeSeconds = 1.0

    /// Bezešvá smyčka šumu (12 s): hnědý = hluboký (vodopád), růžový = vyvážený (déšť), bílý = ostrý.
    /// Konec plynule přechází do začátku, takže při opakování není slyšet šev.
    public static func noise(_ type: NoiseType, sampleRate: Double, using rng: inout some RandomNumberGenerator) -> [Float] {
        let length = Int(loopSeconds * sampleRate)
        let fade = Int(crossfadeSeconds * sampleRate)
        var raw = [Float](repeating: 0, count: length + fade)
        var b0: Float = 0, b1: Float = 0, b2: Float = 0, b3: Float = 0, b4: Float = 0, b5: Float = 0, b6: Float = 0, last: Float = 0
        for i in raw.indices {
            let w = Float.random(in: -1..<1, using: &rng)
            switch type {
            case .white, .off:
                raw[i] = w * 0.5
            case .pink:
                // Paul Kellet – refined pink noise
                b0 = 0.99886 * b0 + w * 0.0555179
                b1 = 0.99332 * b1 + w * 0.0750759
                b2 = 0.969 * b2 + w * 0.153852
                b3 = 0.8665 * b3 + w * 0.3104856
                b4 = 0.55 * b4 + w * 0.5329522
                b5 = -0.7616 * b5 - w * 0.016898
                raw[i] = (b0 + b1 + b2 + b3 + b4 + b5 + b6 + w * 0.5362) * 0.11
                b6 = w * 0.115926
            case .brown:
                last = (last + 0.02 * w) / 1.02
                raw[i] = last * 3.5
            }
        }
        var out = Array(raw[0..<length])
        for i in 0..<fade {
            let t = Float(i) / Float(fade)
            out[i] = raw[i] * t + raw[length + i] * (1 - t)
        }
        return out
    }

    /// Jemná zvonkohra: tři tóny po 0,18 s, náběh 20 ms a doznění 1,2 s; vrchol 0,25.
    public static func chime(_ kind: Chime, sampleRate: Double) -> [Float] {
        let start = 0.02, step = 0.18, attack = 0.02, decay = 1.2, stop = 1.3
        let notes = kind.notes
        let total = Int((start + Double(notes.count - 1) * step + stop) * sampleRate)
        var out = [Float](repeating: 0, count: total)
        for (n, frequency) in notes.enumerated() {
            let t0 = start + Double(n) * step
            let first = Int(t0 * sampleRate), last = min(total, Int((t0 + stop) * sampleRate))
            for i in first..<last {
                let t = Double(i) / sampleRate - t0
                let gain: Double
                if t < attack {
                    gain = 0.25 * t / attack
                } else if t < decay {
                    gain = 0.25 * pow(0.0001 / 0.25, (t - attack) / (decay - attack))
                } else {
                    gain = 0.0001
                }
                out[i] += Float(gain * sin(2 * .pi * frequency * t))
            }
        }
        return out
    }
}
