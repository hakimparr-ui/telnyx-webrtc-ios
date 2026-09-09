import AVFoundation
import ObjectiveC.runtime
import WebRTC
import XCTest
@testable import TelnyxRTC

final class CallingCallKitAudioSessionTests: XCTestCase {
    private var client: TxClient!
    private var rtc: RTCAudioSession!
    private var session: AVAudioSession!
    private var recorder: CallKitAudioSessionRecorder!
    private var activationRecorder: OperatingSystemAudioActivationRecorder!
    private var originalManual = false
    private var originalEnabled = false
    private var originalActive = false
    private var originalInterrupted = false
    private var originalActivationCount = 0
    private var originalCategory: AVAudioSession.Category!
    private var originalMode: AVAudioSession.Mode!
    private var originalOptions: AVAudioSession.CategoryOptions = []
    private var originalPreferredSampleRate: Double = 0
    private var originalPreferredBufferDuration: TimeInterval = 0

    override func setUpWithError() throws {
        XCTAssertTrue(Thread.isMainThread)
        session = AVAudioSession.sharedInstance()
        rtc = RTCAudioSession.sharedInstance()
        originalManual = rtc.useManualAudio
        originalEnabled = rtc.isAudioEnabled
        originalActive = rtc.isActive
        originalInterrupted = try XCTUnwrap(rtc.value(forKey: "isInterrupted") as? Bool)
        originalActivationCount = try activationCount()
        originalCategory = session.category
        originalMode = session.mode
        originalOptions = session.categoryOptions
        originalPreferredSampleRate = session.preferredSampleRate
        originalPreferredBufferDuration = session.preferredIOBufferDuration
        rtc.useManualAudio = true
        rtc.isAudioEnabled = false
        // These tests exercise the real WebRTC notification and reference count
        // implementation. No peer or physical microphone is started.
        rtc.setValue(false, forKey: "isActive")
        rtc.setValue(false, forKey: "isInterrupted")
        activationRecorder = try OperatingSystemAudioActivationRecorder(session: session)
        recorder = CallKitAudioSessionRecorder()
        rtc.add(recorder)
        client = TxClient()
    }

    override func tearDownWithError() throws {
        recorder?.onInterruptionEnd = nil
        client?.disableAudioSession(audioSession: session)
        if let rtc {
            rtc.remove(recorder)
            XCTAssertEqual(try activationCount(), originalActivationCount)
            // Keep later tests independent even if an ownership assertion fails.
            for _ in 0..<16 {
                let count = try activationCount()
                if count == originalActivationCount { break }
                if count > originalActivationCount {
                    rtc.audioSessionDidDeactivate(session)
                } else {
                    rtc.audioSessionDidActivate(session)
                }
            }
            rtc.setValue(originalActive, forKey: "isActive")
            rtc.setValue(originalInterrupted, forKey: "isInterrupted")
            rtc.isAudioEnabled = originalEnabled
            rtc.useManualAudio = originalManual
            try? session.setCategory(originalCategory, mode: originalMode, options: originalOptions)
            try? session.setPreferredSampleRate(originalPreferredSampleRate)
            try? session.setPreferredIOBufferDuration(originalPreferredBufferDuration)
        }
        client?.disconnect()
        client = nil
        activationRecorder?.restore()
        activationRecorder = nil
        recorder = nil
        rtc = nil
        session = nil
    }

    func testPreparationConfiguresRecordingWithoutActivationOrDevicePermission() throws {
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])

        try client.prepareAudioSessionForCallKit()

        XCTAssertEqual(session.category, .playAndRecord)
        XCTAssertEqual(session.mode, .voiceChat)
        XCTAssertTrue(session.categoryOptions.contains(.allowBluetooth))
        XCTAssertTrue(rtc.useManualAudio)
        XCTAssertFalse(rtc.isAudioEnabled)
        XCTAssertFalse(rtc.isActive)
        XCTAssertEqual(try activationCount(), originalActivationCount)
        XCTAssertEqual(recorder.interruptionEnds, 0)
        XCTAssertEqual(recorder.devicePermissions, [])
        XCTAssertEqual(activationRecorder.requests, [])
    }

    func testPreparationReturnsTheConfigurationErrorWithoutAcceptingAudio() throws {
        let expected = NSError(domain: "CallingCallKitAudioSessionTests", code: 73)
        let failure = try AudioSessionConfigurationFailure(session: rtc, error: expected)
        defer { failure.restore() }

        XCTAssertThrowsError(try client.prepareAudioSessionForCallKit()) { error in
            XCTAssertEqual((error as NSError).domain, expected.domain)
            XCTAssertEqual((error as NSError).code, expected.code)
        }

        XCTAssertFalse(rtc.isAudioEnabled)
        XCTAssertFalse(rtc.isActive)
        XCTAssertEqual(try activationCount(), originalActivationCount)
        XCTAssertEqual(recorder.interruptionEnds, 0)
        XCTAssertEqual(activationRecorder.requests, [])
        failure.restore()
        try client.prepareAudioSessionForCallKit()
        XCTAssertEqual(session.category, .playAndRecord, "A failed preparation must release its lock")
        XCTAssertFalse(rtc.isAudioEnabled)
    }

    func testActivationAndDeactivationOnlyReportTheExternalOwner() throws {
        try client.prepareAudioSessionForCallKit()

        client.enableAudioSession(audioSession: session)

        XCTAssertTrue(rtc.isActive)
        XCTAssertTrue(rtc.isAudioEnabled)
        XCTAssertEqual(try activationCount(), originalActivationCount + 1)
        XCTAssertEqual(recorder.interruptionEnds, 1)
        XCTAssertEqual(recorder.devicePermissions, [true])

        client.disableAudioSession(audioSession: session)

        XCTAssertFalse(rtc.isActive)
        XCTAssertFalse(rtc.isAudioEnabled)
        XCTAssertEqual(try activationCount(), originalActivationCount)
        XCTAssertEqual(recorder.devicePermissions, [true, false])
        XCTAssertEqual(activationRecorder.requests, [])
    }

    func testRepeatedActivationNotifiesAgainWithoutAddingAnOwnerOrDisablingAudio() throws {
        client.enableAudioSession(audioSession: session)
        for _ in 0..<3 {
            client.enableAudioSession(audioSession: session)
            XCTAssertEqual(try activationCount(), originalActivationCount + 1)
            XCTAssertTrue(rtc.isAudioEnabled)
        }

        XCTAssertEqual(recorder.interruptionEnds, 4)
        XCTAssertEqual(recorder.devicePermissions, [true])
        XCTAssertEqual(activationRecorder.requests, [])
    }

    func testCallKitReactivationClearsInterruptionWithTheEnabledFlagAlreadyTrue() throws {
        client.enableAudioSession(audioSession: session)
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: session,
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue,
            ]
        )
        XCTAssertFalse(rtc.isActive)
        XCTAssertEqual(rtc.value(forKey: "isInterrupted") as? Bool, true)
        XCTAssertTrue(rtc.isAudioEnabled, "The enabled flag does not prove interruption recovery")

        client.enableAudioSession(audioSession: session)

        XCTAssertTrue(rtc.isActive)
        XCTAssertEqual(rtc.value(forKey: "isInterrupted") as? Bool, false)
        XCTAssertEqual(try activationCount(), originalActivationCount + 1)
        XCTAssertEqual(recorder.interruptionEnds, 2)
        XCTAssertEqual(recorder.devicePermissions, [true])
        XCTAssertEqual(activationRecorder.requests, [])
    }

    func testPropertyAndCallbackShareOneBalancedActivation() throws {
        client.enableAudioSession(audioSession: session)
        client.isAudioDeviceEnabled = true
        client.isAudioDeviceEnabled = true

        XCTAssertEqual(try activationCount(), originalActivationCount + 1)
        XCTAssertTrue(client.isAudioDeviceEnabled)
        XCTAssertEqual(recorder.devicePermissions, [true])

        client.disableAudioSession(audioSession: session)
        client.isAudioDeviceEnabled = false
        client.disableAudioSession(audioSession: session)

        XCTAssertEqual(try activationCount(), originalActivationCount)
        XCTAssertEqual(recorder.devicePermissions, [true, false])
        XCTAssertEqual(activationRecorder.requests, [])
    }

    func testClientWithoutActivationCannotReleaseAnExistingOwner() throws {
        rtc.audioSessionDidActivate(session)
        rtc.isAudioEnabled = true
        defer {
            rtc.audioSessionDidDeactivate(session)
            rtc.isAudioEnabled = false
        }

        client.disableAudioSession(audioSession: session)
        client.isAudioDeviceEnabled = false

        XCTAssertEqual(try activationCount(), originalActivationCount + 1)
        XCTAssertTrue(rtc.isActive)
        XCTAssertTrue(rtc.isAudioEnabled)
        XCTAssertEqual(recorder.devicePermissions, [true])
        XCTAssertEqual(activationRecorder.requests, [])
    }

    func testSynchronousDelegateRevocationIsNotUndoneByActivation() throws {
        recorder.onInterruptionEnd = { [weak client, weak session] in
            guard let session else { return }
            client?.disableAudioSession(audioSession: session)
        }

        client.enableAudioSession(audioSession: session)

        XCTAssertEqual(try activationCount(), originalActivationCount)
        XCTAssertFalse(rtc.isActive)
        XCTAssertFalse(rtc.isAudioEnabled)
        XCTAssertEqual(recorder.devicePermissions, [])
        XCTAssertEqual(activationRecorder.requests, [])
    }

    private func activationCount() throws -> Int {
        // The exact pinned WebRTC runtime keeps this counter behind its ObjC
        // private accessor. Read its real value instead of mirroring SDK state.
        try XCTUnwrap(rtc.value(forKey: "activationCount") as? NSNumber).intValue
    }
}

private final class CallKitAudioSessionRecorder: NSObject, RTCAudioSessionDelegate {
    var interruptionEnds = 0
    var devicePermissions: [Bool] = []
    var onInterruptionEnd: (() -> Void)?

    func audioSessionDidEndInterruption(
        _ session: RTCAudioSession,
        shouldResumeSession: Bool
    ) {
        interruptionEnds += 1
        onInterruptionEnd?()
    }

    func audioSession(_ session: RTCAudioSession, didChangeCanPlayOrRecord value: Bool) {
        devicePermissions.append(value)
    }
}

private final class OperatingSystemAudioActivationRecorder {
    private typealias SimpleBlock = @convention(block) (
        AVAudioSession, Bool, AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool
    private typealias OptionsBlock = @convention(block) (
        AVAudioSession, Bool, UInt, AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool
    private var replacements: [(ObjectiveC.Method, IMP, IMP)] = []
    private(set) var requests: [Bool] = []

    init(session: AVAudioSession) throws {
        guard let sessionClass = object_getClass(session) else {
            throw NSError(domain: "CallingCallKitAudioSessionTests", code: 1)
        }
        let simple = try XCTUnwrap(class_getInstanceMethod(
            sessionClass, NSSelectorFromString("setActive:error:")
        ))
        let options = try XCTUnwrap(class_getInstanceMethod(
            sessionClass, NSSelectorFromString("setActive:withOptions:error:")
        ))
        let simpleBlock: SimpleBlock = { [weak self] _, active, error in
            self?.requests.append(active)
            error?.pointee = nil
            return true
        }
        let optionsBlock: OptionsBlock = { [weak self] _, active, _, error in
            self?.requests.append(active)
            error?.pointee = nil
            return true
        }
        replace(simple, with: imp_implementationWithBlock(simpleBlock))
        replace(options, with: imp_implementationWithBlock(optionsBlock))
    }

    private func replace(_ method: ObjectiveC.Method, with replacement: IMP) {
        replacements.append((method, method_getImplementation(method), replacement))
        method_setImplementation(method, replacement)
    }

    func restore() {
        for (method, original, replacement) in replacements.reversed() {
            method_setImplementation(method, original)
            imp_removeBlock(replacement)
        }
        replacements.removeAll()
    }

    deinit { restore() }
}

private final class AudioSessionConfigurationFailure {
    private typealias FailureBlock = @convention(block) (
        RTCAudioSession,
        RTCAudioSessionConfiguration,
        AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool
    private let method: ObjectiveC.Method
    private let original: IMP
    private var replacement: IMP?

    init(session: RTCAudioSession, error: NSError) throws {
        method = try XCTUnwrap(class_getInstanceMethod(
            object_getClass(session), NSSelectorFromString("setConfiguration:error:")
        ))
        original = method_getImplementation(method)
        let block: FailureBlock = { _, _, outError in
            outError?.pointee = error
            return false
        }
        let replacement = imp_implementationWithBlock(block)
        self.replacement = replacement
        method_setImplementation(method, replacement)
    }

    func restore() {
        guard let replacement else { return }
        method_setImplementation(method, original)
        self.replacement = nil
        imp_removeBlock(replacement)
    }

    deinit { restore() }
}
