import Foundation
import AVFAudio

// MARK: - Configuration

/// Cloud transcription settings, snapshotted out of SettingsStore so the engine
/// (which is not main-actor bound) never reaches back into observable state.
struct CloudTranscriptionConfig: Equatable {
    var isEnabled = false
    var model = "microsoft/mai-transcribe-1.5"
    var apiKey = ""

    /// OpenAI-compatible transcription endpoint. OpenRouter by default; any
    /// provider exposing /audio/transcriptions works unchanged.
    var endpoint = URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!

    var isUsable: Bool { isEnabled && !apiKey.isEmpty && !model.isEmpty }
}

/// Kept off `TranscriptionServiceProtocol` on purpose: cloud configuration is an
/// implementation detail of one backend, and putting it on the frozen contract would
/// force every test double to carry a method it has no use for.
protocol CloudConfigurableTranscriber: AnyObject {
    func updateCloudConfig(_ config: CloudTranscriptionConfig)
}

// MARK: - Session

/// Batch cloud transcription. Mic buffers are downsampled to 16 kHz mono PCM16 as
/// they arrive, held in memory, then uploaded as one WAV when the user releases the
/// key.
///
/// There are no partial results: the OpenAI-compatible transcription endpoint is
/// request/response, not a stream, so `onPartial` is never called and the HUD shows
/// the waveform alone while recording. Everything else in the pipeline (dictionary,
/// formatting, insertion) is unaffected.
///
/// The converted audio is retained after upload so `TranscriptionEngine` can replay
/// it into a local engine when the network fails, rather than losing the dictation.
final class CloudTranscriptionSession: TranscriptionBackendSession, @unchecked Sendable {

    var onPartial: (@Sendable (String) -> Void)?
    let engineKind: TranscriptionEngineKind = .cloud
    let resolvedLocaleIdentifier: String

    /// A cloud round trip on a long dictation legitimately outlives the 10s that is
    /// generous for an on-device engine.
    var finishTimeoutSeconds: Double { 30 }

    private static let targetSampleRate = 16_000.0
    /// 16 kHz mono PCM16 is 32 KB/s, so this caps a runaway hands-free session at
    /// about 19 MB rather than letting it grow until the app is killed.
    private static let maxRecordedSeconds = 600.0

    private let config: CloudTranscriptionConfig
    private let languageCode: String?
    private let targetFormat: AVAudioFormat

    private let lock = NSLock()
    private var samples: [Int16] = []
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var torndown = false
    private var didWarnAboutCap = false

    init?(config: CloudTranscriptionConfig, locale: Locale) {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: true
        ) else { return nil }
        self.config = config
        self.targetFormat = format
        self.resolvedLocaleIdentifier = locale.identifier
        // ISO-639-1 is what the endpoint expects; a full identifier like "tr_TR" is not
        // accepted, and omitting it entirely lets the provider auto-detect.
        self.languageCode = locale.language.languageCode?.identifier
    }

    // MARK: - TranscriptionBackendSession

    func accept(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let done = torndown
        lock.unlock()
        guard !done else { return }
        guard let converted = convert(buffer) else { return }
        append(converted)
    }

    func finish() async throws -> String {
        let shouldRun: Bool = {
            lock.lock(); defer { lock.unlock() }
            guard !torndown else { return false }
            torndown = true
            return true
        }()
        guard shouldRun else { return "" }

        let audio = recordedSamples()
        guard !audio.isEmpty else { return "" }
        return try await upload(wav: Self.makeWAV(samples: audio, sampleRate: Int(Self.targetSampleRate)))
    }

    func cancel() {
        lock.lock()
        torndown = true
        samples.removeAll()
        lock.unlock()
    }

    /// Always empty: with no partial results there is nothing accumulated to salvage
    /// when finish() times out. The replay path below is what protects the dictation.
    func snapshotText() -> String { "" }

    /// Converted audio kept for the local-engine replay after a network failure.
    func recordedSamples() -> [Int16] {
        lock.lock(); defer { lock.unlock() }
        return samples
    }

    // MARK: - Upload

    private func upload(wav: Data) async throws -> String {
        var fields = ["model": config.model]
        if let languageCode { fields["language"] = languageCode }
        let (body, contentType) = Self.multipart(fields: fields, filename: "audio.wav", audio: wav)

        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            Log.asr.error("cloud transcription request failed: \(error.localizedDescription)")
            throw DictationError.transcriptionFailed("network")
        }

        guard let http = response as? HTTPURLResponse else {
            throw DictationError.transcriptionFailed("malformed response")
        }
        guard (200..<300).contains(http.statusCode) else {
            // The body carries the actionable part (no credit, bad key, unknown model),
            // but it is provider text so it stays in the log rather than the HUD.
            let detail = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            Log.asr.error("cloud transcription returned \(http.statusCode): \(String(detail))")
            throw DictationError.transcriptionFailed("HTTP \(http.statusCode)")
        }
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let text = json["text"] as? String
        else {
            throw DictationError.transcriptionFailed("unexpected response body")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Sample accumulation (audio thread)

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.int16ChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        lock.lock()
        defer { lock.unlock() }
        let cap = Int(Self.maxRecordedSeconds * Self.targetSampleRate)
        guard samples.count < cap else {
            if !didWarnAboutCap {
                didWarnAboutCap = true
                Log.asr.notice("cloud recording hit the \(Int(Self.maxRecordedSeconds))s cap; ignoring further audio")
            }
            return
        }
        samples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: frames))
    }

    /// Same multi-callback contract as SpeechAnalyzerSession: the converter may ask for
    /// input several times per call, and we only ever have the one buffer to hand it.
    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0 else { return nil }
        let inputFormat = buffer.format

        lock.lock()
        if converter == nil || !formatsMatch(converterInputFormat, inputFormat) {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
            converterInputFormat = inputFormat
            if converter == nil {
                Log.asr.error("could not build cloud audio converter for the current input format")
            }
        }
        let activeConverter = converter
        lock.unlock()
        guard let activeConverter else { return nil }

        let ratio = targetFormat.sampleRate / max(inputFormat.sampleRate, 1)
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: max(capacity, 32)) else { return nil }

        var delivered = false
        var conversionError: NSError?
        let status = activeConverter.convert(to: output, error: &conversionError) { _, inputStatus in
            if delivered {
                inputStatus.pointee = .noDataNow
                return nil
            }
            delivered = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error else {
            Log.asr.error("cloud audio convert failed: \(conversionError?.localizedDescription ?? "unknown")")
            return nil
        }
        guard output.frameLength > 0 else { return nil }
        return output
    }

    private func formatsMatch(_ a: AVAudioFormat?, _ b: AVAudioFormat) -> Bool {
        guard let a else { return false }
        return a.sampleRate == b.sampleRate
            && a.channelCount == b.channelCount
            && a.commonFormat == b.commonFormat
            && a.isInterleaved == b.isInterleaved
    }

    /// Rebuilds PCM buffers from the retained samples so a local engine can consume the
    /// same audio. Chunked rather than handed over as one huge buffer because the
    /// on-device engines expect to be fed at roughly capture granularity.
    static func buffers(from samples: [Int16], chunkFrames: Int = 4096) -> [AVAudioPCMBuffer] {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: targetSampleRate, channels: 1, interleaved: true
        ) else { return [] }

        var result: [AVAudioPCMBuffer] = []
        var index = 0
        while index < samples.count {
            let count = min(chunkFrames, samples.count - index)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
                  let channel = buffer.int16ChannelData else { break }
            samples.withUnsafeBufferPointer { pointer in
                channel[0].update(from: pointer.baseAddress! + index, count: count)
            }
            buffer.frameLength = AVAudioFrameCount(count)
            result.append(buffer)
            index += count
        }
        return result
    }

    // MARK: - WAV / multipart encoding

    /// Minimal 44-byte RIFF header plus little-endian PCM16 payload. Every provider
    /// tested accepts this; there is no reason to pull in an audio file library.
    static func makeWAV(samples: [Int16], sampleRate: Int) -> Data {
        let channels = 1
        let bitsPerSample = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataBytes = samples.count * 2

        var data = Data(capacity: 44 + dataBytes)
        func append32(_ value: Int) { withUnsafeBytes(of: UInt32(value).littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: Int) { withUnsafeBytes(of: UInt16(value).littleEndian) { data.append(contentsOf: $0) } }

        data.append(contentsOf: Array("RIFF".utf8))
        append32(36 + dataBytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append32(16)             // PCM chunk size
        append16(1)              // format: PCM
        append16(channels)
        append32(sampleRate)
        append32(byteRate)
        append16(blockAlign)
        append16(bitsPerSample)
        data.append(contentsOf: Array("data".utf8))
        append32(dataBytes)
        samples.withUnsafeBufferPointer { pointer in
            pointer.forEach { sample in
                withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
            }
        }
        return data
    }

    static func multipart(fields: [String: String], filename: String, audio: Data) -> (Data, String) {
        let boundary = "murmur-\(UUID().uuidString)"
        var body = Data()
        for (key, value) in fields.sorted(by: { $0.key < $1.key }) {
            body.append(contentsOf: Array("--\(boundary)\r\n".utf8))
            body.append(contentsOf: Array("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n".utf8))
            body.append(contentsOf: Array("\(value)\r\n".utf8))
        }
        body.append(contentsOf: Array("--\(boundary)\r\n".utf8))
        body.append(contentsOf: Array(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(contentsOf: Array("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(audio)
        body.append(contentsOf: Array("\r\n--\(boundary)--\r\n".utf8))
        return (body, "multipart/form-data; boundary=\(boundary)")
    }
}
