import AVFoundation
import ObjectiveC.runtime
import WebRTC
import XCTest
@testable import TelnyxRTC

final class CallingAudioOwnershipTests: XCTestCase {
    private var peer: Peer!
    private var rtc: RTCAudioSession!
    private var originalManualAudio = false
    private var originalAudioEnabled = false

    override func setUpWithError() throws {
        XCTAssertTrue(Thread.isMainThread)
        rtc = RTCAudioSession.sharedInstance()
        originalManualAudio = rtc.useManualAudio
        originalAudioEnabled = rtc.isAudioEnabled
        rtc.useManualAudio = true
        rtc.isAudioEnabled = false
        peer = Peer(iceServers: [], isAnswering: true)
        drainMainQueue(for: 0.1)
        XCTAssertTrue(peer.isAudioTrackEnabled)
        XCTAssertFalse(rtc.isAudioEnabled)
    }

    override func tearDownWithError() throws {
        // The old implementation schedules work for up to two seconds.
        // Let it finish before releasing the real peer and restoring the singleton.
        drainMainQueue(for: 2)
        peer.connection?.close()
        peer = nil
        rtc.isAudioEnabled = originalAudioEnabled
        rtc.useManualAudio = originalManualAudio
        rtc = nil
    }

    func testManualAudioRecoveryDoesNotTemporarilyMuteOrStartReset() {
        var resetCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: Notification.Name(InternalConfig.NotificationNames.acmResetStarted),
            object: nil,
            queue: .main
        ) { _ in resetCount += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        peer.resetAudioDeviceModule()

        XCTAssertTrue(peer.isAudioTrackEnabled, "Recovery must not interrupt the app owned microphone")
        XCTAssertEqual(resetCount, 0, "Manual audio recovery must not start SDK session resets")
    }

    func testOverlappingRecoveryDoesNotLeaveMicrophoneMuted() {
        peer.resetAudioDeviceModule()
        peer.resetAudioDeviceModule()

        drainMainQueue(for: 2)

        XCTAssertTrue(peer.isAudioTrackEnabled, "A second reset must not restore the first reset's temporary mute")
        XCTAssertFalse(rtc.isAudioEnabled, "Only the audio owner may activate the device")
    }

    func testUserMuteDuringRecoveryStaysMuted() {
        peer.resetAudioDeviceModule()
        peer.muteUnmuteAudio(mute: true)

        drainMainQueue(for: 2)

        XCTAssertFalse(peer.isAudioTrackEnabled, "Recovery must not undo a later user mute")
    }

    func testAlreadyMutedMicrophoneIsNotBrieflyUnmuted() {
        peer.muteUnmuteAudio(mute: true)
        peer.resetAudioDeviceModule()

        drainMainQueue(for: 0.3)

        XCTAssertFalse(peer.isAudioTrackEnabled, "Recovery must not transmit audio while the user is muted")
        drainMainQueue(for: 1.7)
        XCTAssertFalse(peer.isAudioTrackEnabled)
    }

    func testRecoveryDoesNotActivateDeviceBeforeCallKitPermission() {
        peer.resetAudioDeviceModule()

        drainMainQueue(for: 2)

        XCTAssertFalse(rtc.isAudioEnabled, "A scheduled recovery must preserve CallKit's disabled device")
    }

    func testRecoveryPreservesAudioEnabledByTheOwner() {
        rtc.isAudioEnabled = true
        XCTAssertTrue(rtc.isAudioEnabled)

        peer.resetAudioDeviceModule()

        XCTAssertTrue(rtc.isAudioEnabled, "Recovery must preserve the owner's active audio permission")
        drainMainQueue(for: 2)
        XCTAssertTrue(rtc.isAudioEnabled, "Delayed recovery must not disable the owner's audio")
        XCTAssertTrue(peer.isAudioTrackEnabled, "Recovery must preserve the owner's unmuted track")
    }

    func testOwnerRevocationAfterRecoveryEntryStaysRevoked() {
        rtc.isAudioEnabled = true
        XCTAssertTrue(rtc.isAudioEnabled)

        peer.resetAudioDeviceModule()
        rtc.isAudioEnabled = false
        XCTAssertFalse(rtc.isAudioEnabled)

        drainMainQueue(for: 2)

        XCTAssertFalse(rtc.isAudioEnabled, "Queued recovery must not restore permission revoked by the owner")
    }

    func testAutomaticSpeakerRestorationPreservesManualReceiverChoice() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [])
        let recorder = try AudioOutputOverrideRecorder(session: session)
        defer { recorder.restore() }
        let client = TxClient()
        defer { client.disconnect() }
        client.setEarpiece()
        XCTAssertEqual(
            recorder.requestedPorts,
            [AVAudioSession.PortOverride.none.rawValue],
            "The recorder must observe an explicit route request through the real method"
        )
        XCTAssertFalse(client.isSpeakerEnabled)
        recorder.clear()

        client.restoreSpeakerAfterReconnect()

        XCTAssertTrue(recorder.requestedPorts.isEmpty, "Automatic recovery must not write the audio route")
        XCTAssertFalse(client.isSpeakerEnabled, "Automatic restoration must not override the app's receiver choice")
        drainMainQueue(for: 1.2)
        XCTAssertTrue(recorder.requestedPorts.isEmpty, "A delayed retry must not write the audio route")
        XCTAssertFalse(client.isSpeakerEnabled, "A delayed retry must respect manual audio ownership")
    }

    private func drainMainQueue(for interval: TimeInterval) {
        let drained = expectation(description: "Main queue callbacks completed")
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { drained.fulfill() }
        wait(for: [drained], timeout: interval + 3)
    }
}

private final class AudioOutputOverrideRecorder {
    private typealias OriginalImplementation = @convention(c) (
        AnyObject,
        Selector,
        UInt,
        AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool

    private typealias RecordingBlock = @convention(block) (
        AVAudioSession,
        UInt,
        AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> Bool

    private let method: ObjectiveC.Method
    private let originalImplementation: IMP
    private var recordingImplementation: IMP?
    private let lock = NSLock()
    private var recordedPorts: [UInt] = []

    init(session: AVAudioSession) throws {
        let selector = #selector(AVAudioSession.overrideOutputAudioPort(_:))
        guard let sessionClass = object_getClass(session),
              let method = class_getInstanceMethod(sessionClass, selector) else {
            throw NSError(
                domain: "CallingAudioOwnershipTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The real audio route method is unavailable"]
            )
        }
        self.method = method
        originalImplementation = method_getImplementation(method)
        let original = unsafeBitCast(
            originalImplementation,
            to: OriginalImplementation.self
        )
        let block: RecordingBlock = { [weak self] session, port, error in
            self?.record(port)
            return original(session, selector, port, error)
        }
        let implementation = imp_implementationWithBlock(block)
        recordingImplementation = implementation
        method_setImplementation(method, implementation)
    }

    var requestedPorts: [UInt] {
        lock.lock()
        defer { lock.unlock() }
        return recordedPorts
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        recordedPorts.removeAll()
    }

    func restore() {
        guard let implementation = recordingImplementation else { return }
        method_setImplementation(method, originalImplementation)
        recordingImplementation = nil
        imp_removeBlock(implementation)
    }

    private func record(_ port: UInt) {
        lock.lock()
        defer { lock.unlock() }
        recordedPorts.append(port)
    }

    deinit {
        restore()
    }
}
