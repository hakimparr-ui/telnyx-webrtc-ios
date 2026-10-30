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
    private var originalGlobalConfiguration: RTCAudioSessionConfiguration!
    private var originalGlobalOptions: AVAudioSession.CategoryOptions = []
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
        originalGlobalConfiguration = RTCAudioSessionConfiguration.webRTC()
        originalGlobalOptions = originalGlobalConfiguration.categoryOptions
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
        originalGlobalConfiguration.categoryOptions = originalGlobalOptions
        XCTAssertTrue(RTCAudioSessionConfiguration.webRTC() === originalGlobalConfiguration)
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
        XCTAssertFalse(session.categoryOptions.contains(.duckOthers))
        XCTAssertFalse(session.categoryOptions.contains(.mixWithOthers))
        XCTAssertFalse(session.categoryOptions.contains(.defaultToSpeaker))
        XCTAssertTrue(rtc.useManualAudio)
        XCTAssertFalse(rtc.isAudioEnabled)
        XCTAssertFalse(rtc.isActive)
        XCTAssertEqual(try activationCount(), originalActivationCount)
        XCTAssertEqual(recorder.interruptionEnds, 0)
        XCTAssertEqual(recorder.devicePermissions, [])
        XCTAssertEqual(activationRecorder.requests, [])
    }

    func testPreparationClearsInheritedMixingAndSpeakerDefaults() throws {
        try session.setCategory(
            .playAndRecord, mode: .voiceChat,
            options: [.duckOthers, .mixWithOthers, .allowBluetooth, .defaultToSpeaker]
        )
        XCTAssertTrue(session.categoryOptions.contains(.mixWithOthers))

        try client.prepareAudioSessionForCallKit()

        XCTAssertEqual(session.category, .playAndRecord)
        XCTAssertEqual(session.mode, .voiceChat)
        XCTAssertTrue(session.categoryOptions.contains(.allowBluetooth))
        XCTAssertFalse(session.categoryOptions.contains(.duckOthers))
        XCTAssertFalse(session.categoryOptions.contains(.mixWithOthers))
        XCTAssertFalse(session.categoryOptions.contains(.defaultToSpeaker))
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

    func testEngineStartupKeepsPreparedPolicyAndExternalOwner() throws {
        try checkEngineBoundary(inheritGlobalOptions: false, changeCurrentAfterPreparation: false)
    }

    func testEngineStartupClearsInheritedGlobalOptions() throws {
        try checkEngineBoundary(inheritGlobalOptions: true, changeCurrentAfterPreparation: false)
    }

    func testEngineBoundaryDetectsAChangedCurrentConfiguration() throws {
        try checkEngineBoundary(inheritGlobalOptions: true, changeCurrentAfterPreparation: true)
    }

    private func checkEngineBoundary(
        inheritGlobalOptions: Bool,
        changeCurrentAfterPreparation: Bool
    ) throws {
        if inheritGlobalOptions {
            RTCAudioSessionConfiguration.webRTC().categoryOptions = [
                .duckOthers, .mixWithOthers, .allowBluetooth, .defaultToSpeaker
            ]
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }
        try client.prepareAudioSessionForCallKit()
        let actualPreparedOptions = session.categoryOptions.rawValue
        let requestedPreparedOptions = RTCAudioSessionConfiguration.webRTC().categoryOptions.rawValue
        XCTAssertEqual(requestedPreparedOptions, AVAudioSession.CategoryOptions.allowBluetooth.rawValue)
        client.isAudioDeviceEnabled = true
        XCTAssertEqual(try activationCount(), originalActivationCount + 1)
        if changeCurrentAfterPreparation {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        }
        let boundary = try EngineConfigurationBoundaryRecorder(session: rtc)
        defer { boundary.restore() }
        rtc.lockForConfiguration()
        var error: NSError?
        let accepted = try boundary.invokeEngineConfiguration(error: &error)
        rtc.unlockForConfiguration()
        XCTAssertFalse(accepted)
        XCTAssertEqual(error?.domain, EngineConfigurationBoundaryRecorder.stopDomain)
        XCTAssertEqual(boundary.configurationCalls, 1)
        XCTAssertEqual(boundary.activeRequests, [true])
        XCTAssertEqual(boundary.categoryWrites, changeCurrentAfterPreparation ? 1 : 0)
        XCTAssertEqual(session.category, .playAndRecord)
        XCTAssertEqual(session.mode, .voiceChat)
        XCTAssertEqual(session.categoryOptions.rawValue, requestedPreparedOptions)
        XCTAssertEqual(activationRecorder.requests, [])
        XCTAssertEqual(try activationCount(), originalActivationCount + 2)
        print("ENGINE_BOUNDARY actualPreparedOptions=\(actualPreparedOptions) requestedPreparedOptions=\(requestedPreparedOptions) inherited=\(inheritGlobalOptions) changedAfterPreparation=\(changeCurrentAfterPreparation) categoryWrites=\(boundary.categoryWrites) actualActivationRequests=\(activationRecorder.requests.count)")
        rtc.lockForConfiguration()
        try boundary.releaseEngineReference(error: &error)
        rtc.unlockForConfiguration()
        XCTAssertEqual(try activationCount(), originalActivationCount + 1)
        XCTAssertTrue(rtc.isAudioEnabled)
        XCTAssertTrue(rtc.isActive)
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

private final class EngineConfigurationBoundaryRecorder {
    static let stopDomain = "CallingEngineBoundaryIntentionalStop"
    private typealias ConfigurationFunction = @convention(c) (
        AnyObject, Selector, RTCAudioSessionConfiguration, Bool,
        AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool
    private typealias ConfigurationBlock = @convention(block) (
        RTCAudioSession, RTCAudioSessionConfiguration, Bool,
        AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool
    private typealias CategoryFunction = @convention(c) (
        AnyObject, Selector, NSString, NSString, UInt,
        AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool
    private typealias CategoryBlock = @convention(block) (
        RTCAudioSession, NSString, NSString, UInt,
        AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool
    private typealias EngineFunction = @convention(c) (
        AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool
    private let session: RTCAudioSession
    private var replacements: [(ObjectiveC.Method, IMP, IMP)] = []
    private let configure: EngineFunction
    private let unconfigure: EngineFunction
    private(set) var configurationCalls = 0
    private(set) var categoryWrites = 0
    private(set) var activeRequests: [Bool] = []

    init(session: RTCAudioSession) throws {
        self.session = session
        let cls = try XCTUnwrap(object_getClass(session))
        let configureMethod = try XCTUnwrap(class_getInstanceMethod(cls, NSSelectorFromString("configureWebRTCSession:")))
        let unconfigureMethod = try XCTUnwrap(class_getInstanceMethod(cls, NSSelectorFromString("unconfigureWebRTCSession:")))
        configure = unsafeBitCast(method_getImplementation(configureMethod), to: EngineFunction.self)
        unconfigure = unsafeBitCast(method_getImplementation(unconfigureMethod), to: EngineFunction.self)
        let configurationSelector = NSSelectorFromString("setConfiguration:active:error:")
        let configurationMethod = try XCTUnwrap(class_getInstanceMethod(cls, configurationSelector))
        let originalConfiguration = unsafeBitCast(method_getImplementation(configurationMethod), to: ConfigurationFunction.self)
        let configurationBlock: ConfigurationBlock = { [weak self] session, config, active, error in
            self?.configurationCalls += 1
            self?.activeRequests.append(active)
            let applied = originalConfiguration(session, configurationSelector, config, active, error)
            guard applied else { return false }
            error?.pointee = NSError(domain: Self.stopDomain, code: 1)
            return false
        }
        replace(configurationMethod, with: imp_implementationWithBlock(configurationBlock))
        let categorySelector = NSSelectorFromString("setCategory:mode:options:error:")
        let categoryMethod = try XCTUnwrap(class_getInstanceMethod(cls, categorySelector))
        let originalCategory = unsafeBitCast(method_getImplementation(categoryMethod), to: CategoryFunction.self)
        let categoryBlock: CategoryBlock = { [weak self] session, category, mode, options, error in
            self?.categoryWrites += 1
            return originalCategory(session, categorySelector, category, mode, options, error)
        }
        replace(categoryMethod, with: imp_implementationWithBlock(categoryBlock))
    }

    func invokeEngineConfiguration(error: AutoreleasingUnsafeMutablePointer<NSError?>?) throws -> Bool {
        configure(session, NSSelectorFromString("configureWebRTCSession:"), error)
    }

    func releaseEngineReference(error: AutoreleasingUnsafeMutablePointer<NSError?>?) throws {
        XCTAssertTrue(unconfigure(session, NSSelectorFromString("unconfigureWebRTCSession:"), error))
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
