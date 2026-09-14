import Foundation
import AVFoundation
import CoreAudio
import Clibltc

struct ReceivedTimecode: Equatable {
    var hours: Int
    var minutes: Int
    var seconds: Int
    var frames: Int
    var fps: Double

    var totalSeconds: Double {
        Double(hours * 3600 + minutes * 60 + seconds) + Double(frames) / max(fps, 1)
    }

    var smpte: String {
        String(format: "%02d:%02d:%02d:%02d", hours, minutes, seconds, frames)
    }
}

/// Captures one channel from an audio input and decodes LTC with libltc.
final class LTCReceiver: @unchecked Sendable {
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var decoder: OpaquePointer?
    private var sampleRate: Double = 48_000
    private var fps: Double = 25
    private var channelIndex: Int = 0
    private var availableChannels: Int = 1
    private var position: Int64 = 0
    private var lastTC: ReceivedTimecode?
    private var lastFrameTime = Date.distantPast
    private var peak: Float = 0
    private var generation: UInt64 = 0

    var onTimecode: ((ReceivedTimecode) -> Void)?
    var onStatus: ((String?) -> Void)?

    private(set) var isRunning = false
    private(set) var currentDeviceUID: String?
    private(set) var activeChannel: Int = 0

    var inputPeak: Float {
        lock.lock(); defer { lock.unlock() }
        return peak
    }

    func start(deviceUID: String?, channel: Int, fps: Double) {
        stop()
        generation &+= 1
        let gen = generation
        self.fps = fps
        self.channelIndex = max(0, channel)

        ensureMicAccess { [weak self] granted in
            guard let self else { return }
            guard gen == self.generation else { return }
            guard granted else {
                self.onStatus?("Permesso microfono/input audio negato. Abilitalo in Impostazioni di Sistema → Privacy → Microfono.")
                return
            }
            self.startEngine(deviceUID: deviceUID, channel: channel, fps: fps, generation: gen)
        }
    }

    func stop() {
        generation &+= 1
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            if engine.isRunning { engine.stop() }
        }
        engine = nil
        lock.lock()
        if let decoder {
            ltc_decoder_free(decoder)
        }
        decoder = nil
        position = 0
        peak = 0
        lock.unlock()
        isRunning = false
    }

    private func startEngine(deviceUID: String?, channel: Int, fps: Double, generation: UInt64) {
        let engine = AVAudioEngine()
        let input = engine.inputNode

        if let uid = deviceUID, let deviceID = AudioDeviceList.deviceID(forUID: uid) {
            do {
                try Self.setInputDevice(engine: engine, deviceID: deviceID)
                currentDeviceUID = uid
            } catch {
                onStatus?("Device audio: \(error.localizedDescription)")
                currentDeviceUID = uid
            }
        } else {
            currentDeviceUID = AudioDeviceList.defaultInputUID()
        }

        // Try to open the device with enough channels for LTC channel selection.
        let deviceChannels = max(1, AudioDeviceList.inputChannelCount(forUID: currentDeviceUID))
        _ = Self.trySetInputChannelCount(engine: engine, channels: deviceChannels)

        engine.prepare()

        let hwFormat = input.inputFormat(forBus: 0)
        if hwFormat.sampleRate <= 0 || hwFormat.channelCount == 0 {
            // Node not ready yet — use sane defaults; tap format will still be float32.
            sampleRate = 48_000
        } else {
            sampleRate = hwFormat.sampleRate
        }

        let nodeChannels = max(1, Int(hwFormat.channelCount))
        // What we can actually tap is limited by the input node after prepare.
        availableChannels = max(1, nodeChannels)
        let wanted = max(0, channel)
        let selected = min(wanted, availableChannels - 1)
        channelIndex = selected
        activeChannel = selected

        let apv = max(1, Int((sampleRate / fps).rounded()))
        guard let dec = ltc_decoder_create(Int32(apv), 32) else {
            onStatus?("Impossibile creare decoder LTC.")
            return
        }
        lock.lock()
        decoder = dec
        lock.unlock()

        // Same approach as when it worked: float32 non-interleaved.
        // Prefer the channel count the node actually exposes; never fail hard.
        let tapFormat = Self.makeFloatFormat(sampleRate: sampleRate, channels: availableChannels)
            ?? Self.makeFloatFormat(sampleRate: sampleRate, channels: min(2, availableChannels))
            ?? Self.makeFloatFormat(sampleRate: 48_000, channels: 1)!

        availableChannels = Int(tapFormat.channelCount)
        channelIndex = min(channelIndex, availableChannels - 1)
        activeChannel = channelIndex

        input.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }

        do {
            try engine.start()
            guard generation == self.generation else {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
                return
            }
            self.engine = engine
            isRunning = true

            var note = "LTC ch\(activeChannel + 1)/\(availableChannels) · \(Int(sampleRate)) Hz · \(Int(fps)) fps"
            if wanted >= availableChannels {
                note += " · (richiesto ch\(wanted + 1), node ne espone \(availableChannels))"
            }
            onStatus?(note)
        } catch {
            onStatus?("Audio engine: \(error.localizedDescription)")
            stop()
        }
    }

    private static func makeFloatFormat(sampleRate: Double, channels: Int) -> AVAudioFormat? {
        let rate = sampleRate > 0 ? sampleRate : 48_000
        let ch = max(1, min(channels, 64))
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: rate,
            channels: AVAudioChannelCount(ch),
            interleaved: false
        )
    }

    private func process(buffer: AVAudioPCMBuffer) {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }

        guard let channels = buffer.floatChannelData else { return }

        let available = max(1, Int(buffer.format.channelCount))
        let ch = min(max(0, channelIndex), available - 1)
        let samples = channels[ch]

        var localPeak: Float = 0
        for i in 0..<frames {
            let a = fabsf(samples[i])
            if a > localPeak { localPeak = a }
        }

        lock.lock()
        peak = max(peak * 0.9, localPeak)
        guard let decoder else {
            lock.unlock()
            return
        }
        ltc_decoder_write_float(decoder, samples, frames, ltc_off_t(position))
        position += Int64(frames)

        var ext = LTCFrameExt()
        var decoded: ReceivedTimecode?
        while ltc_decoder_read(decoder, &ext) != 0 {
            var stime = SMPTETimecode()
            ltc_frame_to_time(&stime, &ext.ltc, 0)
            let tc = ReceivedTimecode(
                hours: Int(stime.hours),
                minutes: Int(stime.mins),
                seconds: Int(stime.secs),
                frames: Int(stime.frame),
                fps: self.fps
            )
            lastTC = tc
            lastFrameTime = Date()
            decoded = tc
        }
        lock.unlock()

        if let decoded {
            DispatchQueue.main.async {
                self.onTimecode?(decoded)
            }
        }
    }

    var hasLock: Bool {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(lastFrameTime) < 0.5
    }

    var latest: ReceivedTimecode? {
        lock.lock(); defer { lock.unlock() }
        return lastTC
    }

    private static func setInputDevice(engine: AVAudioEngine, deviceID: AudioDeviceID) throws {
        guard let audioUnit = engine.inputNode.audioUnit else {
            throw NSError(domain: "LTCReceiver", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "AudioUnit input non disponibile"
            ])
        }
        var id = deviceID
        let err = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard err == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(err), userInfo: [
                NSLocalizedDescriptionKey: "Impossibile selezionare l’input audio (\(err))"
            ])
        }
    }

    /// Best-effort: ask the HAL input unit for N channels so channel picker can work.
    @discardableResult
    private static func trySetInputChannelCount(engine: AVAudioEngine, channels: Int) -> Bool {
        guard let audioUnit = engine.inputNode.audioUnit, channels > 0 else { return false }
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat
                | kAudioFormatFlagIsNonInterleaved
                | kAudioFormatFlagsNativeEndian,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        // Bus 1 = input side of AUHAL; Scope Output = client-facing pull format.
        let err = AudioUnitSetProperty(
            audioUnit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output,
            1,
            &asbd,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        return err == noErr
    }

    private func ensureMicAccess(completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            DispatchQueue.main.async { completion(true) }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { completion(ok) }
            }
        case .denied, .restricted:
            DispatchQueue.main.async { completion(false) }
        @unknown default:
            DispatchQueue.main.async { completion(false) }
        }
    }
}
