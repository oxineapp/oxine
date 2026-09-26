import Accelerate
import Foundation

/// Turns a tap's sample ring into a handful of 0…1 frequency bands, for
/// visualisers. Pull-based: call `bands()` once per frame; it drains whatever
/// arrived since the last call, transforms the newest 1024 frames and returns
/// smoothed band levels. Main-actor only; nothing here runs on the IO thread.
@MainActor
public final class SpectrumAnalyzer {
    private let ring: SampleRing
    private let sampleRate: Double
    private let bandCount: Int
    private let size = 1024
    private let log2n: vDSP_Length = 10
    private nonisolated(unsafe) let setup: FFTSetup
    private var window: [Float]
    private var scratch: [Float]
    private var mono: [Float]
    private var real: [Float]
    private var imag: [Float]
    private var magnitudes: [Float]
    private var smoothed: [Float]
    private var edges: [Int] = []
    private var last = Date.distantPast
    /// Slow-moving ceiling the bands are scaled against, so quiet tracks still
    /// dance and loud ones don't pin.
    private var ceiling: Float = 0.02

    public init?(ring: SampleRing, sampleRate: Double, bands: Int) {
        guard let setup = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2)) else { return nil }
        self.setup = setup
        self.ring = ring
        self.sampleRate = sampleRate
        self.bandCount = max(bands, 1)
        window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        scratch = [Float](repeating: 0, count: 16_384)
        mono = [Float](repeating: 0, count: size)
        real = [Float](repeating: 0, count: size / 2)
        imag = [Float](repeating: 0, count: size / 2)
        magnitudes = [Float](repeating: 0, count: size / 2)
        smoothed = [Float](repeating: 0, count: self.bandCount)
        // Log-spaced from the kick to the hats: equal-width bins would give the
        // bass one bar and the cymbals four.
        let lo = 50.0, hi = min(12_000.0, sampleRate / 2 - 1)
        let binHz = sampleRate / Double(size)
        edges = (0...self.bandCount).map { i in
            let f = lo * pow(hi / lo, Double(i) / Double(self.bandCount))
            return min(max(Int(f / binHz), 1), size / 2 - 1)
        }
        for i in 1..<edges.count where edges[i] <= edges[i - 1] { edges[i] = min(edges[i - 1] + 1, size / 2 - 1) }
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    public func bands() -> [Float] {
        // Drain everything that arrived, keeping the newest `size` frames.
        var got = 0
        scratch.withUnsafeMutableBufferPointer { buf in
            while true {
                let n = ring.read(into: buf)
                if n == 0 { break }
                got = n
                if n < buf.count { break }
            }
        }
        let now = Date()
        let dt = Float(min(max(now.timeIntervalSince(last), 0), 0.1))
        last = now
        let frames = got / 2
        if frames > 0 {
            let take = min(frames, size)
            let start = (frames - take) * 2
            for i in 0..<size { mono[i] = 0 }
            for i in 0..<take { mono[size - take + i] = (scratch[start + i * 2] + scratch[start + i * 2 + 1]) * 0.5 }
            vDSP_vmul(mono, 1, window, 1, &mono, 1, vDSP_Length(size))
            real.withUnsafeMutableBufferPointer { r in
                imag.withUnsafeMutableBufferPointer { im in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: im.baseAddress!)
                    mono.withUnsafeBufferPointer { m in
                        m.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(size / 2))
                }
            }
        }
        var peak: Float = 0
        var raw = [Float](repeating: 0, count: bandCount)
        if frames > 0 {
            for b in 0..<bandCount {
                var m: Float = 0
                for bin in edges[b]..<max(edges[b + 1], edges[b] + 1) { m = max(m, magnitudes[bin]) }
                // Tilt up with frequency: music's energy falls off as it rises.
                raw[b] = m / Float(size) * (1 + Float(b) * 0.9)
                peak = max(peak, raw[b])
            }
        }
        ceiling = max(peak, ceiling - dt * ceiling * 0.35, 0.004)
        for b in 0..<bandCount {
            let target = min(pow(raw[b] / ceiling, 0.7), 1)
            smoothed[b] = target >= smoothed[b] ? smoothed[b] + (target - smoothed[b]) * 0.75
                                                : max(target, smoothed[b] - dt * 3.2)
        }
        return smoothed
    }
}
