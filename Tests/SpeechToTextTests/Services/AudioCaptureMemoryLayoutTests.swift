import CoreAudio
import Foundation
import Testing

// MARK: - Core Audio MemoryLayout sanity tests
//
// `AudioCaptureService.setInputDevice(...)` hands Core Audio raw pointers
// plus explicit byte sizes via `AudioValueTranslation`. A silent platform
// drift in any of those sizes would turn the device-UID → `AudioDeviceID`
// lookup into a memory-safety bug without touching a single line of our
// code, and the call site is hardware-gated from CI (real mic required).
//
// This file exists so CI *can* catch that drift without hardware. Pure
// logic, no device access, `.fast`-tagged so it runs on every PR.

@Suite("AudioCapture MemoryLayout", .tags(.fast))
struct AudioCaptureMemoryLayoutTests {

    @Test("AudioDeviceID is a 4-byte UInt32")
    func audioDeviceID_size() {
        #expect(MemoryLayout<AudioDeviceID>.size == 4)
    }

    @Test("CFString reference is 8 bytes on 64-bit macOS")
    func cfString_size() {
        // Core Audio's `kAudioHardwarePropertyDeviceForUID` reads the
        // CFStringRef through `AudioValueTranslation.mInputData`. The
        // byte size we pass as `mInputDataSize` must match the reference
        // size, which is 8 on all macOS targets we support.
        #expect(MemoryLayout<CFString>.size == 8)
    }

    @Test("AudioValueTranslation is 32 bytes")
    func audioValueTranslation_size() {
        // Two `UnsafeMutableRawPointer`s (8 bytes each) + two `UInt32`s
        // (4 bytes each, 4 bytes trailing pad) = 32 bytes.
        //
        // If this ever drifts, the `&translation` pointer in
        // `AudioObjectGetPropertyData` reads/writes the wrong stride and
        // the Core Audio call silently misbehaves.
        #expect(MemoryLayout<AudioValueTranslation>.size == 32)
    }

    @Test("AudioObjectPropertyAddress is 12 bytes")
    func audioObjectPropertyAddress_size() {
        // Three `UInt32`s — used by `AudioObjectGetPropertyData`'s
        // `inAddress` parameter. Guarded here so a future struct change
        // doesn't break the property-lookup call site.
        #expect(MemoryLayout<AudioObjectPropertyAddress>.size == 12)
    }
}
