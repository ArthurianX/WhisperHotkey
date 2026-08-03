import Foundation

/// Decides whether to send whisper-server a throwaway inference when recording
/// starts, so the real request isn't the one that pays to page the model back in.
///
/// ggml's Metal backend keeps the model's ~1.6 GB of buffers wired only for
/// `keep_alive` seconds after the last compute (180 s by default — see
/// `ggml_metal_rsets_init` in ggml/src/ggml-metal/ggml-metal-device.m). Once
/// that lapses the OS is free to compress or swap them out, and the next
/// request stalls for seconds while they fault back in.
///
/// `warmUpAfterSeconds <= 0` disables warming entirely.
func shouldWarmUp(idleSeconds: TimeInterval, warmUpAfterSeconds: TimeInterval) -> Bool {
    guard warmUpAfterSeconds > 0 else { return false }
    return idleSeconds >= warmUpAfterSeconds
}

/// A canonical 16 kHz mono 16-bit PCM WAV of pure silence — the cheapest input
/// that still makes whisper run a full encoder pass and touch the weights.
/// Matches the recorder's format so the server takes the same code path.
func silentWavData(seconds: Double, sampleRate: Int) -> Data {
    let channels = 1
    let bitsPerSample = 16
    let bytesPerSample = bitsPerSample / 8
    let byteRate = sampleRate * channels * bytesPerSample
    let blockAlign = channels * bytesPerSample
    let payloadBytes = max(0, Int(Double(sampleRate) * seconds)) * blockAlign

    var data = Data(capacity: 44 + payloadBytes)
    func appendASCII(_ s: String) { data.append(contentsOf: Array(s.utf8)) }
    func appendLE32(_ v: UInt32) { for i in 0..<4 { data.append(UInt8((v >> (8 * UInt32(i))) & 0xFF)) } }
    func appendLE16(_ v: UInt16) { for i in 0..<2 { data.append(UInt8((v >> (8 * UInt16(i))) & 0xFF)) } }

    appendASCII("RIFF")
    appendLE32(UInt32(36 + payloadBytes))
    appendASCII("WAVE")
    appendASCII("fmt ")
    appendLE32(16)                       // PCM fmt chunk length
    appendLE16(1)                        // format tag: uncompressed PCM
    appendLE16(UInt16(channels))
    appendLE32(UInt32(sampleRate))
    appendLE32(UInt32(byteRate))
    appendLE16(UInt16(blockAlign))
    appendLE16(UInt16(bitsPerSample))
    appendASCII("data")
    appendLE32(UInt32(payloadBytes))
    data.append(Data(repeating: 0, count: payloadBytes))
    return data
}
