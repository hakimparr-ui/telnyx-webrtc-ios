import AVFoundation
import WebRTC
import XCTest
@testable import TelnyxRTC

final class CallingRTPIntegrationTests: XCTestCase {
    private var call: Call?
    private var remote: RTCPeerConnection?
    private var remoteDelegate: LocalPeerDelegate?
    private var localFactory: RTCPeerConnectionFactory?
    private var remoteFactory: RTCPeerConnectionFactory?
    private var localDevice: CallingSyntheticAudioDevice?
    private var remoteDevice: CallingSyntheticAudioDevice?
    private var socket: LocalSignalingSocket?
    private var observer: CallStateRecorder?
    private var client: TxClient?
    private var measurements: [[String: Any]] = []
    private var connectedAt: TimeInterval = 0
    private var originalManual = false
    private var originalEnabled = false
    private var originalCategory: AVAudioSession.Category!
    private var originalMode: AVAudioSession.Mode!
    private var originalOptions: AVAudioSession.CategoryOptions = []

    override func setUpWithError() throws {
        XCTAssertTrue(Thread.isMainThread)
        let rtc = RTCAudioSession.sharedInstance()
        originalManual = rtc.useManualAudio
        originalEnabled = rtc.isAudioEnabled
        let session = AVAudioSession.sharedInstance()
        originalCategory = session.category
        originalMode = session.mode
        originalOptions = session.categoryOptions
        rtc.useManualAudio = true
        rtc.isAudioEnabled = true
        RTCInitializeSSL()
    }

    override func tearDownWithError() throws {
        if let call = call, call.callState.isConsideredActive { call.hangup() }
        call?.peer?.dispose()
        remote?.close()
        (localFactory as? CallingDeferredDescriptionFactory)?.releaseRemoteDescriptionCompletion()
        drain(for: 0.5)
        call = nil
        remote = nil
        socket = nil
        observer = nil
        client?.disconnect()
        client = nil
        remoteDelegate = nil
        localFactory = nil
        remoteFactory = nil
        if let device = localDevice { XCTAssertTrue(device.stopAndWait(3), "Local PCM thread must exit") }
        if let device = remoteDevice { XCTAssertTrue(device.stopAndWait(3), "Remote PCM thread must exit") }
        localDevice = nil
        remoteDevice = nil

        let rtc = RTCAudioSession.sharedInstance()
        rtc.lockForConfiguration()
        try? AVAudioSession.sharedInstance().setCategory(originalCategory, mode: originalMode, options: originalOptions)
        rtc.isAudioEnabled = originalEnabled
        rtc.useManualAudio = originalManual
        rtc.unlockForConfiguration()
        if !measurements.isEmpty {
            let data = try JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys])
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "Synthetic audio measurements"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        measurements = []
    }

    func testIncomingPrefersOpusOverOfferedG722AndKeepsAudioBeyondTwoMinutesUntilRemoteBye() throws {
        try connectIncoming(offeredCodecs: ["G722", "opus"], preferredCodecs: appPreferences, expectedCodec: "opus")
        try exerciseLifetime(expectedCodec: "opus")
        try receiveRemoteBye(includeReason: true)
        try assertTerminal(origin: .remoteSignaling)
        XCTAssertEqual(observer?.terminalReasons.last?.causeCode, 16)
        XCTAssertEqual(observer?.terminalReasons.last?.sipCode, 200)
        XCTAssertEqual(socket?.methods.filter { $0 == .BYE }.count, 0, "Received BYE must not become a local hangup request")
    }

    func testIncomingKeepsG722FallbackAndAudioBeyondTwoMinutesUntilLocalHangup() throws {
        try connectIncoming(offeredCodecs: ["G722"], preferredCodecs: appPreferences, expectedCodec: "G722")
        try exerciseLifetime(expectedCodec: "G722")
        call?.hangup()
        try assertTerminal(origin: .localRequest)
        XCTAssertEqual(socket?.methods.filter { $0 == .BYE }.count, 1)
    }

    func testDefaultIncomingG722WaitsForQueuedHangupAcknowledgement() throws {
        try connectIncoming(offeredCodecs: ["G722"], preferredCodecs: nil, expectedCodec: "G722")
        try assertAudioWindow(label: "default incoming", duration: 2, expectedCodec: "G722")
        let queued = call?.queueHangup(using: try XCTUnwrap(socket), sessionId: "local-session")
        XCTAssertNotNil(queued)
        drain(for: 0.3)
        XCTAssertEqual(call?.callState, .ACTIVE)
        XCTAssertTrue(observer?.terminalReasons.isEmpty == true, "Queueing a BYE is not acknowledgement")
        call?.confirmQueuedHangup()
        try assertTerminal(origin: .queuedLocalAcknowledged)
        XCTAssertEqual(socket?.methods.filter { $0 == .BYE }.count, 1)
    }

    func testIncomingNegotiatesSecondPreferredPCMUCodec() throws {
        try connectIncoming(offeredCodecs: ["PCMU"], preferredCodecs: appPreferences, expectedCodec: "PCMU")
        try exerciseLifetime(expectedCodec: "PCMU")
        call?.hangup()
        try assertTerminal(origin: .localRequest)
    }

    func testIncomingNegotiatesPreferredOpusWhenG722IsOfferedFirst() throws {
        try connectIncoming(offeredCodecs: ["G722", "opus"], preferredCodecs: appPreferences, expectedCodec: "opus")
        try assertAudioWindow(label: "initial incoming preference", duration: 2, expectedCodec: "opus")
        call?.hangup()
        try assertTerminal(origin: .localRequest)
    }

    func testAttachDispatcherRetainsStoredCodecPreferenceOnReplacementCall() throws {
        try connectIncoming(offeredCodecs: ["G722", "opus"], preferredCodecs: appPreferences,
                            expectedCodec: "opus", attachThroughClient: true)
        XCTAssertEqual(call?.preferredAudioCodecs?.map(\.mimeType), ["audio/opus", "audio/PCMU"])
        try assertAudioWindow(label: "reattached incoming preference", duration: 3, expectedCodec: "opus")
        call?.hangup()
        try assertTerminal(origin: .localRequest)
    }

    func testOutgoingOfferKeepsExplicitOpusThenPCMUOrdering() throws {
        let audio = CallingSyntheticAudioDevice(toneFrequency: 600, expectedFrequency: 1100)
        localDevice = audio
        let factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil, audioDevice: audio)
        localFactory = factory
        let stateObserver = CallStateRecorder()
        let signaling = LocalSignalingSocket()
        observer = stateObserver
        socket = signaling
        var inviteSDP: String?
        signaling.onMessage = { message in
            if message.method == .INVITE { inviteSDP = message.params?["sdp"] as? String }
        }
        let outgoing = Call(callId: UUID(), sessionId: "local-session", socket: signaling,
                            delegate: stateObserver, iceServers: [], useTrickleIce: true,
                            enableCallReports: false, peerFactory: factory)
        call = outgoing
        outgoing.newCall(callerName: "Synthetic endpoint", callerNumber: "local-source",
                         destinationNumber: "local-destination", preferredCodecs: appPreferences)
        try waitUntil("actual outgoing INVITE", timeout: 8) { inviteSDP != nil }
        let lines = try XCTUnwrap(inviteSDP).components(separatedBy: "\r\n")
        let audioLine = try XCTUnwrap(lines.first { $0.hasPrefix("m=audio ") })
        let payloads = audioLine.split(separator: " ").dropFirst(3)
        let codecs = payloads.compactMap { payload in
            lines.first { $0.hasPrefix("a=rtpmap:\(payload) ") }?.split(separator: " ").last?.split(separator: "/").first.map(String.init)
        }
        XCTAssertEqual(codecs.map { $0.lowercased() }, ["opus", "pcmu"])
        outgoing.hangup()
        try assertTerminal(origin: .localRequest)
    }

    func testReceivedByeWithoutReasonStillIdentifiesRemoteSignaling() throws {
        let stateObserver = CallStateRecorder()
        let signaling = LocalSignalingSocket()
        observer = stateObserver
        socket = signaling
        call = Call(callId: UUID(), sessionId: "local-session", socket: signaling,
                    delegate: stateObserver, iceServers: [], enableCallReports: false)
        try receiveRemoteBye(includeReason: false)
        try assertTerminal(origin: .remoteSignaling, expectsPeer: false)
        XCTAssertNil(observer?.terminalReasons.last?.cause)
        XCTAssertNil(observer?.terminalReasons.last?.sipCode)
    }

    func testInvalidIncomingSdpTerminatesAsNegotiationFailureAndNeverBecomesActive() throws {
        let audio = CallingSyntheticAudioDevice(toneFrequency: 600, expectedFrequency: 1100)
        localDevice = audio
        let factory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil, audioDevice: audio)
        localFactory = factory
        let stateObserver = CallStateRecorder()
        let signaling = LocalSignalingSocket()
        observer = stateObserver
        socket = signaling
        let incoming = Call(callId: UUID(), remoteSdp: "invalid incoming SDP", sessionId: "local-session",
                            socket: signaling, delegate: stateObserver, iceServers: [], isAttach: false,
                            useTrickleIce: true, enableCallReports: false, peerFactory: factory)
        incoming.callOptions = TxCallOptions()
        call = incoming

        incoming.answer(preferredCodecs: appPreferences)

        try assertTerminal(origin: .negotiationFailure)
        drain(for: 0.3)
        XCTAssertFalse(stateObserver.states.contains(.ACTIVE), "Rejected SDP must never be reported as an active call")
        XCTAssertEqual(stateObserver.terminalReasons.count, 1)
        XCTAssertEqual(signaling.methods.filter { $0 == .ANSWER }.count, 0)
    }

    func testRemoteByeWhileAnswerCompletionIsPendingCannotResurrectCallOrSendLocalBye() throws {
        try connectIncoming(offeredCodecs: ["G722"], preferredCodecs: appPreferences,
                            expectedCodec: "G722", remoteByeWhileAnswerPending: true)
        XCTAssertEqual(observer?.terminalReasons.count, 1)
        XCTAssertEqual(observer?.terminalReasons.first?.origin, .remoteSignaling)
        XCTAssertFalse(observer?.states.contains(.ACTIVE) ?? true)
        XCTAssertEqual(socket?.methods.filter { $0 == .BYE }.count, 0)
        XCTAssertEqual(socket?.methods.filter { $0 == .ANSWER }.count, 0)
    }

    private var appPreferences: [TxCodecCapability] {
        [TxCodecCapability(mimeType: "audio/opus", clockRate: 48000, channels: 2),
         TxCodecCapability(mimeType: "audio/PCMU", clockRate: 8000, channels: 1)]
    }

    private func connectIncoming(offeredCodecs: [String], preferredCodecs: [TxCodecCapability]?, expectedCodec: String,
                                 remoteByeWhileAnswerPending: Bool = false, attachThroughClient: Bool = false) throws {
        let localAudio = CallingSyntheticAudioDevice(toneFrequency: 600, expectedFrequency: 1100)
        let remoteAudio = CallingSyntheticAudioDevice(toneFrequency: 1100, expectedFrequency: 600)
        localDevice = localAudio
        remoteDevice = remoteAudio
        let incomingFactory: RTCPeerConnectionFactory
        if remoteByeWhileAnswerPending {
            incomingFactory = CallingDeferredDescriptionFactory(encoderFactory: nil, decoderFactory: nil, audioDevice: localAudio)
        } else {
            incomingFactory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil, audioDevice: localAudio)
        }
        let offeringFactory = RTCPeerConnectionFactory(encoderFactory: nil, decoderFactory: nil, audioDevice: remoteAudio)
        localFactory = incomingFactory
        remoteFactory = offeringFactory
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.iceServers = []
        let connectionDelegate = LocalPeerDelegate()
        remoteDelegate = connectionDelegate
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let offeringPeer = try XCTUnwrap(offeringFactory.peerConnection(with: configuration, constraints: constraints, delegate: connectionDelegate))
        remote = offeringPeer
        let source = offeringFactory.audioSource(with: constraints)
        let track = offeringFactory.audioTrack(with: source, trackId: "synthetic-offerer")
        offeringPeer.add(track, streamIds: ["synthetic-local-stream"])
        let transceiver = try XCTUnwrap(offeringPeer.transceivers.first { $0.mediaType == .audio })
        let capabilities = offeringFactory.rtpSenderCapabilities(forKind: kRTCMediaStreamTrackKindAudio).codecs
        let codecs = try offeredCodecs.map { name in
            try XCTUnwrap(capabilities.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }, "Missing real WebRTC codec \(name)")
        }
        transceiver.setCodecPreferences(codecs)
        var offer: RTCSessionDescription?
        var negotiationError: Error?
        offeringPeer.offer(for: constraints) { description, error in
            DispatchQueue.main.async { offer = description; negotiationError = error }
        }
        try waitUntil("local offer", timeout: 5) { offer != nil || negotiationError != nil }
        if let error = negotiationError { throw error }
        var offerSet = false
        offeringPeer.setLocalDescription(try XCTUnwrap(offer)) { error in
            DispatchQueue.main.async { offerSet = true; negotiationError = error }
        }
        try waitUntil("offer ICE gathering", timeout: 8) { offerSet && offeringPeer.iceGatheringState == .complete }
        if let error = negotiationError { throw error }
        let completeOffer = try XCTUnwrap(offeringPeer.localDescription)
        XCTAssertTrue(completeOffer.sdp.contains("a=candidate:"), "The local peer must gather actual host candidates")

        let stateObserver = CallStateRecorder()
        let signaling = LocalSignalingSocket()
        observer = stateObserver
        socket = signaling
        var answerSet = false
        var answerReceived = false
        var wireAnswerSDP: String?
        var pendingCandidates: [RTCIceCandidate] = []
        var candidateErrors: [String] = []
        func addCandidate(_ candidate: RTCIceCandidate) {
            offeringPeer.add(candidate) { error in
                if let error = error { DispatchQueue.main.async { candidateErrors.append(error.localizedDescription) } }
            }
        }
        signaling.onMessage = { message in
            if (message.method == .ANSWER || message.method == .ATTACH), let sdp = message.params?["sdp"] as? String {
                answerReceived = true
                wireAnswerSDP = sdp
                offeringPeer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { error in
                    DispatchQueue.main.async {
                        negotiationError = error
                        answerSet = true
                        pendingCandidates.forEach(addCandidate)
                        pendingCandidates.removeAll()
                    }
                }
            } else if message.method == .CANDIDATE,
                      let sdp = message.params?["candidate"] as? String,
                      let line = message.params?["sdpMLineIndex"] as? NSNumber {
                let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: line.int32Value,
                                               sdpMid: message.params?["sdpMid"] as? String)
                if answerSet { addCandidate(candidate) } else { pendingCandidates.append(candidate) }
            }
        }
        var incoming = Call(callId: UUID(), remoteSdp: completeOffer.sdp, sessionId: "local-session",
                            socket: signaling, delegate: stateObserver, iceServers: [], isAttach: false,
                            useTrickleIce: true, enableCallReports: false, peerFactory: incomingFactory)
        incoming.callOptions = TxCallOptions()
        call = incoming
        if attachThroughClient {
            // Seed the previous Call's stored preference, then exercise the
            // real dispatcher replacement and its actual WebRTC negotiation.
            // Incoming answer preference storage is covered by the long cases.
            incoming.callOptions = TxCallOptions(preferredCodecs: preferredCodecs)
            let previous = incoming
            let previousID = try XCTUnwrap(previous.callInfo?.callId)
            let dispatcher = TxClient()
            client = dispatcher
            dispatcher.peerFactory = incomingFactory
            dispatcher.socketFactory = { signaling }
            try dispatcher.connect(
                txConfig: TxConfig(sipUser: "synthetic-user", password: "synthetic-only",
                                   useTrickleIce: true, enableCallReports: false),
                serverConfiguration: TxServerConfiguration(signalingServer: URL(string: "wss://127.0.0.1"), webRTCIceServers: [])
            )
            dispatcher.calls[previousID] = previous
            let attachData = try JSONSerialization.data(withJSONObject: [
                "jsonrpc": "2.0", "id": UUID().uuidString, "method": "telnyx_rtc.attach",
                "params": ["callID": previousID.uuidString, "sdp": completeOffer.sdp]
            ])
            dispatcher.onMessageReceived(socket: signaling, message: try XCTUnwrap(String(data: attachData, encoding: .utf8)))
            incoming = try XCTUnwrap(dispatcher.calls[previousID])
            XCTAssertFalse(incoming === previous, "ATTACH must exercise the actual replacement Call")
            XCTAssertEqual(incoming.preferredAudioCodecs?.map(\.mimeType), preferredCodecs?.map(\.mimeType))
            incoming.delegate = stateObserver
            call = incoming
        } else {
            incoming.answer(preferredCodecs: preferredCodecs)
        }
        if let deferred = incomingFactory as? CallingDeferredDescriptionFactory {
            try waitUntil("real remote SDP completed behind the test gate", timeout: 5) { deferred.hasDeferredRemoteCompletion }
            XCTAssertFalse(stateObserver.states.contains(.ACTIVE))
            try receiveRemoteBye(includeReason: true)
            try assertTerminal(origin: .remoteSignaling)
            incoming.hangup()
            deferred.releaseRemoteDescriptionCompletion()
            drain(for: 0.4)
            return
        }
        try waitUntil("real incoming RTP connection", timeout: 12) {
            negotiationError != nil || (answerSet && incoming.peer?.connection?.connectionState == .connected && offeringPeer.connectionState == .connected)
        }
        if let error = negotiationError { throw error }
        let effectiveOffer = try XCTUnwrap(incoming.peer?.connection?.remoteDescription)
        let answerSDP = try XCTUnwrap(wireAnswerSDP)
        let negotiation: [String: Any] = [
            "event": "codec negotiation",
            "path": attachThroughClient ? "attach" : "incoming answer",
            "originalOffer": audioPayloadOrder(completeOffer.sdp),
            "effectiveOffer": audioPayloadOrder(effectiveOffer.sdp),
            "answer": audioPayloadOrder(answerSDP)
        ]
        measurements.append(negotiation)
        emitSanitizedEvidence(negotiation, prefix: "CALLING_CODEC_NEGOTIATION")
        XCTAssertTrue(answerReceived, "The remote peer must consume the SDK's actual answer message")
        XCTAssertTrue(candidateErrors.isEmpty, "Local ICE delivery failed: \(candidateErrors)")
        XCTAssertEqual(incoming.callState, .ACTIVE)
        try waitForInitialRTP()
        connectedAt = ProcessInfo.processInfo.systemUptime
        drain(for: 2)
        measurements.append(["event": "connected", "offeredCodecs": offeredCodecs, "expectedCodec": expectedCodec,
                             "answerMessages": signaling.methods.filter { $0 == .ANSWER }.count])
        try assertAudioWindow(label: "initial audio", duration: 2, expectedCodec: expectedCodec)
    }

    private func exerciseLifetime(expectedCodec: String) throws {
        try changeOwnerCategory(speaker: true)
        try assertAudioWindow(label: "speaker category and recovery", duration: 4, expectedCodec: expectedCodec)
        try changeOwnerCategory(speaker: false)
        try assertAudioWindow(label: "receiver category and recovery", duration: 4, expectedCodec: expectedCodec)

        call?.muteAudio()
        call?.peer?.resetAudioDeviceModule()
        call?.peer?.resetAudioDeviceModule()
        drain(for: 1)
        try assertAudioWindow(label: "user mute during overlapping recovery", duration: 2, expectedCodec: expectedCodec, localMuted: true)
        call?.unmuteAudio()
        drain(for: 1)
        try assertAudioWindow(label: "user unmute", duration: 4, expectedCodec: expectedCodec)

        var lateCategoryApplied = false
        while ProcessInfo.processInfo.systemUptime - connectedAt < 122 {
            if !lateCategoryApplied && ProcessInfo.processInfo.systemUptime - connectedAt > 40 {
                try changeOwnerCategory(speaker: true)
                try changeOwnerCategory(speaker: false)
                lateCategoryApplied = true
            }
            try assertAudioWindow(label: "continued audio", duration: 4, expectedCodec: expectedCodec)
        }
        XCTAssertGreaterThan(ProcessInfo.processInfo.systemUptime - connectedAt, 120)
        XCTAssertEqual(call?.callState, .ACTIVE, "A healthy incoming call must not terminate on a lifetime timer")
        XCTAssertTrue(observer?.terminalReasons.isEmpty == true)
    }

    private func changeOwnerCategory(speaker: Bool) throws {
        let rtc = RTCAudioSession.sharedInstance()
        let session = AVAudioSession.sharedInstance()
        let options: AVAudioSession.CategoryOptions = speaker ? [.allowBluetooth, .defaultToSpeaker] : [.allowBluetooth]
        rtc.lockForConfiguration()
        do {
            try session.setCategory(.playAndRecord, mode: .videoChat, options: options)
            rtc.unlockForConfiguration()
        } catch {
            rtc.unlockForConfiguration()
            throw error
        }
        localDevice?.notifyUnchangedAudioParameters()
        remoteDevice?.notifyUnchangedAudioParameters()
        // Feed delayed OS/network notifications through the real Call recovery
        // observer. RTP itself continues on the actual established host pair.
        call?.peer?.onIceConnectionStateChange?(.connected)
        call?.peer?.onIceConnectionStateChange?(.disconnected)
        call?.peer?.onIceConnectionStateChange?(.connected)
        let currentPeer = call?.peer
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { currentPeer?.configureAudioSession() }
        drain(for: 0.4)
        XCTAssertEqual(session.category, .playAndRecord)
        XCTAssertEqual(session.mode, .videoChat, "Delayed peer configuration must preserve the audio owner's mode")
        XCTAssertEqual(session.categoryOptions, options, "Delayed recovery must preserve the audio owner's route category")
        XCTAssertTrue(rtc.useManualAudio)
        XCTAssertTrue(rtc.isAudioEnabled)
    }

    private func assertAudioWindow(label: String, duration: TimeInterval, expectedCodec: String, localMuted: Bool = false) throws {
        let localAudio = try XCTUnwrap(localDevice)
        let remoteAudio = try XCTUnwrap(remoteDevice)
        let localBefore = localAudio.snapshot()
        let remoteBefore = remoteAudio.snapshot()
        let before = try collectStats()
        drain(for: duration)
        let localAfter = localAudio.snapshot()
        let remoteAfter = remoteAudio.snapshot()
        let after = try collectStats()
        let localTone = toneRMS(before: localBefore, after: localAfter, key: "expectedToneEnergy")
        let remoteTone = toneRMS(before: remoteBefore, after: remoteAfter, key: "expectedToneEnergy")
        let localOwnTone = toneRMS(before: localBefore, after: localAfter, key: "ownToneEnergy")
        let remoteOwnTone = toneRMS(before: remoteBefore, after: remoteAfter, key: "ownToneEnergy")
        XCTAssertGreaterThan(delta(localBefore, localAfter, "playoutFrames"), duration * 24000, label)
        XCTAssertGreaterThan(delta(remoteBefore, remoteAfter, "playoutFrames"), duration * 24000, label)
        XCTAssertGreaterThan(localTone, 0.005, "\(label): the SDK must decode the remote synthetic tone")
        XCTAssertGreaterThan(localTone, localOwnTone * 4, "Decoded audio must come from the other endpoint")
        if localMuted {
            XCTAssertLessThan(remoteTone, 0.003, "\(label): recovery must not send the muted local tone")
            XCTAssertTrue(call?.isMuted == true)
        } else {
            XCTAssertGreaterThan(remoteTone, 0.005, "\(label): the remote peer must decode the SDK's synthetic tone")
            XCTAssertGreaterThan(remoteTone, remoteOwnTone * 4, "The remote decoder must receive the SDK endpoint's distinct tone")
            XCTAssertFalse(call?.isMuted ?? true)
        }
        XCTAssertEqual(localAfter["callbackErrors"]?.intValue, 0)
        XCTAssertEqual(remoteAfter["callbackErrors"]?.intValue, 0)
        XCTAssertGreaterThan(after["packetsSent"] as? Double ?? 0, before["packetsSent"] as? Double ?? 0, label)
        XCTAssertGreaterThan(after["packetsReceived"] as? Double ?? 0, before["packetsReceived"] as? Double ?? 0, label)
        XCTAssertEqual((after["sendCodec"] as? String)?.lowercased(), "audio/\(expectedCodec.lowercased())")
        XCTAssertEqual((after["receiveCodec"] as? String)?.lowercased(), "audio/\(expectedCodec.lowercased())")
        XCTAssertEqual(after["sendClockRate"] as? Double, expectedCodec.lowercased() == "opus" ? 48000 : 8000)
        XCTAssertEqual(after["receiveClockRate"] as? Double, expectedCodec.lowercased() == "opus" ? 48000 : 8000)
        XCTAssertEqual(call?.callState, .ACTIVE, label)
        let mediaChecks: [String: Bool] = [
            "localPlayoutProgress": delta(localBefore, localAfter, "playoutFrames") > duration * 24000,
            "remotePlayoutProgress": delta(remoteBefore, remoteAfter, "playoutFrames") > duration * 24000,
            "localDecodedTone": localTone > 0.005 && localTone > localOwnTone * 4,
            "remoteDecodedToneOrUserMute": localMuted ? remoteTone < 0.003 : remoteTone > 0.005 && remoteTone > remoteOwnTone * 4,
            "userMutePreserved": call?.isMuted == localMuted,
            "audioCallbacksSucceeded": localAfter["callbackErrors"]?.intValue == 0 && remoteAfter["callbackErrors"]?.intValue == 0,
            "outboundPacketsProgress": (after["packetsSent"] as? Double ?? 0) > (before["packetsSent"] as? Double ?? 0),
            "inboundPacketsProgress": (after["packetsReceived"] as? Double ?? 0) > (before["packetsReceived"] as? Double ?? 0),
            "callActive": call?.callState == .ACTIVE
        ]
        let formatChecks: [String: Bool] = [
            "sendCodec": (after["sendCodec"] as? String)?.lowercased() == "audio/\(expectedCodec.lowercased())",
            "receiveCodec": (after["receiveCodec"] as? String)?.lowercased() == "audio/\(expectedCodec.lowercased())",
            "sendClockRate": after["sendClockRate"] as? Double == (expectedCodec.lowercased() == "opus" ? 48000 : 8000),
            "receiveClockRate": after["receiveClockRate"] as? Double == (expectedCodec.lowercased() == "opus" ? 48000 : 8000)
        ]
        measurements.append(["event": label, "elapsed": ProcessInfo.processInfo.systemUptime - connectedAt,
                             "windowSeconds": duration, "localDecodedToneRMS": localTone,
                             "remoteDecodedToneRMS": remoteTone, "localMuted": localMuted, "rtp": after,
                             "mediaChecks": mediaChecks, "formatChecks": formatChecks])
        if mediaChecks.values.contains(false) {
            emitSanitizedEvidence(["event": label, "mediaChecks": mediaChecks], prefix: "CALLING_MEDIA_CHECK_FAILURE")
        }
    }

    private func audioPayloadOrder(_ sdp: String) -> [[String: Any]] {
        var inAudio = false
        var payloads: [String] = []
        var codecMappings: [String: [String: Any]] = [:]
        for rawLine in sdp.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("m=") {
                if inAudio { break }
                inAudio = line.hasPrefix("m=audio ")
                if inAudio { payloads = line.split(separator: " ").dropFirst(3).map(String.init) }
                continue
            }
            guard inAudio, line.hasPrefix("a=rtpmap:") else { continue }
            let parts = line.dropFirst("a=rtpmap:".count).split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let encoding = parts[1].split(separator: "/")
            guard encoding.count >= 2, let clockRate = Int(encoding[1]), clockRate > 0,
                  clockRate <= 384000 else { continue }
            let codec = String(encoding[0])
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
            guard !codec.isEmpty, codec.count <= 32, codec.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { continue }
            var mapping: [String: Any] = ["codec": codec, "clockRate": clockRate]
            if encoding.count > 2, let channels = Int(encoding[2]), channels > 0 && channels <= 8 {
                mapping["channels"] = channels
            }
            codecMappings[String(parts[0])] = mapping
        }
        return payloads.compactMap { payload in
            guard let number = Int(payload), (0...127).contains(number) else { return nil }
            var mapping = codecMappings[payload] ?? ["codec": "unmapped"]
            mapping["payloadType"] = number
            return mapping
        }
    }

    private func emitSanitizedEvidence(_ value: [String: Any], prefix: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let encoded = String(data: data, encoding: .utf8) else {
            XCTFail("Unable to encode the bounded synthetic evidence")
            return
        }
        print("\(prefix) \(encoded)")
    }

    private func collectStats() throws -> [String: Any] {
        let connection = try XCTUnwrap(call?.peer?.connection)
        var report: RTCStatisticsReport?
        connection.statistics { value in DispatchQueue.main.async { report = value } }
        try waitUntil("RTP statistics", timeout: 3) { report != nil }
        let statistics = try XCTUnwrap(report).statistics
        let outbound = try XCTUnwrap(statistics.values.first { $0.type == "outbound-rtp" })
        let inbound = try XCTUnwrap(statistics.values.first { $0.type == "inbound-rtp" })
        let sendCodecID = try XCTUnwrap(outbound.values["codecId"] as? String)
        let receiveCodecID = try XCTUnwrap(inbound.values["codecId"] as? String)
        let sendCodec = try XCTUnwrap(statistics[sendCodecID])
        let receiveCodec = try XCTUnwrap(statistics[receiveCodecID])
        return ["packetsSent": (outbound.values["packetsSent"] as? NSNumber)?.doubleValue ?? 0,
                "packetsReceived": (inbound.values["packetsReceived"] as? NSNumber)?.doubleValue ?? 0,
                "bytesSent": (outbound.values["bytesSent"] as? NSNumber)?.doubleValue ?? 0,
                "bytesReceived": (inbound.values["bytesReceived"] as? NSNumber)?.doubleValue ?? 0,
                "sendCodec": sendCodec.values["mimeType"] as? String ?? "missing",
                "receiveCodec": receiveCodec.values["mimeType"] as? String ?? "missing",
                "sendClockRate": (sendCodec.values["clockRate"] as? NSNumber)?.doubleValue ?? 0,
                "receiveClockRate": (receiveCodec.values["clockRate"] as? NSNumber)?.doubleValue ?? 0]
    }

    private func waitForInitialRTP() throws {
        let connection = try XCTUnwrap(call?.peer?.connection)
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + 5
        var lastEvidence: [String: Any] = [:]
        repeat {
            guard call?.peer?.connection === connection, call?.callState == .ACTIVE,
                  connection.connectionState == .connected else {
                XCTFail("The call or its transport ended before initial RTP became available")
                throw NSError(domain: "CallingRTPIntegrationTests", code: 2)
            }
            var report: RTCStatisticsReport?
            connection.statistics { value in DispatchQueue.main.async { report = value } }
            let remaining = max(0.01, deadline - ProcessInfo.processInfo.systemUptime)
            try waitUntil("initial RTP statistics callback", timeout: remaining) { report != nil }
            let statistics = try XCTUnwrap(report).statistics
            let outbound = statistics.values.first { $0.type == "outbound-rtp" }
            let inbound = statistics.values.first { $0.type == "inbound-rtp" }
            let sent = (outbound?.values["packetsSent"] as? NSNumber)?.doubleValue ?? 0
            let received = (inbound?.values["packetsReceived"] as? NSNumber)?.doubleValue ?? 0
            let sendCodec = (outbound?.values["codecId"] as? String).flatMap { statistics[$0] }
            let receiveCodec = (inbound?.values["codecId"] as? String).flatMap { statistics[$0] }
            lastEvidence = [
                "event": "initial RTP readiness",
                "waitSeconds": ProcessInfo.processInfo.systemUptime - started,
                "outboundStreamPresent": outbound != nil, "inboundStreamPresent": inbound != nil,
                "packetsSent": sent, "packetsReceived": received,
                "sendCodecPresent": sendCodec != nil, "receiveCodecPresent": receiveCodec != nil
            ]
            if sent > 0, received > 0, sendCodec != nil, receiveCodec != nil {
                measurements.append(lastEvidence)
                return
            }
            drain(for: min(0.05, max(0, deadline - ProcessInfo.processInfo.systemUptime)))
        } while ProcessInfo.processInfo.systemUptime < deadline

        // Only initial startup may wait for stream creation. Subsequent window
        // samples stay strict so disappearing RTP cannot be hidden by retries.
        measurements.append(lastEvidence)
        emitSanitizedEvidence(lastEvidence, prefix: "CALLING_MEDIA_CHECK_FAILURE")
        XCTFail("No bidirectional RTP with codec statistics within five seconds of transport connection")
        throw NSError(domain: "CallingRTPIntegrationTests", code: 3)
    }

    private func receiveRemoteBye(includeReason: Bool) throws {
        remote?.close()
        let incoming = try XCTUnwrap(call)
        var params: [String: Any] = ["callID": incoming.signalingCallId.uuidString]
        if includeReason { params.merge(["cause": "NORMAL_CLEARING", "causeCode": 16, "sipCode": 200]) { _, new in new } }
        let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": UUID().uuidString,
                                                              "method": "telnyx_rtc.bye", "params": params])
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let message = try XCTUnwrap(Message().decode(message: text))
        let disconnectedClient = TxClient()
        client = disconnectedClient
        incoming.handleVertoMessage(message: message, dataMessage: text, txClient: disconnectedClient)
    }

    private func assertTerminal(origin: CallTerminationOrigin, expectsPeer: Bool = true) throws {
        try waitUntil("terminal delegate", timeout: 3) { self.observer?.terminalReasons.count == 1 }
        XCTAssertEqual(observer?.terminalReasons.first?.origin, origin)
        if expectsPeer {
            XCTAssertEqual(call?.peer?.connection?.connectionState, .closed)
            drain(for: 0.4)
            XCTAssertFalse(localDevice?.isRecording ?? true, "Ending the only call must stop its recording device")
        }
        measurements.append(["event": "terminated", "origin": origin.rawValue,
                             "elapsed": connectedAt == 0 ? 0 : ProcessInfo.processInfo.systemUptime - connectedAt])
    }

    private func delta(_ before: [String: NSNumber], _ after: [String: NSNumber], _ key: String) -> Double {
        (after[key]?.doubleValue ?? 0) - (before[key]?.doubleValue ?? 0)
    }

    private func toneRMS(before: [String: NSNumber], after: [String: NSNumber], key: String) -> Double {
        sqrt(max(0, delta(before, after, key)) / max(1, delta(before, after, "playoutFrames")))
    }

    private func waitUntil(_ label: String, timeout: TimeInterval, condition: () -> Bool) throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() && ProcessInfo.processInfo.systemUptime < deadline { drain(for: 0.02) }
        guard condition() else {
            XCTFail("Timed out waiting for \(label)")
            throw NSError(domain: "CallingRTPIntegrationTests", code: 1, userInfo: [NSLocalizedDescriptionKey: label])
        }
    }

    private func drain(for interval: TimeInterval) {
        let deadline = Date(timeIntervalSinceNow: interval)
        while Date() < deadline { RunLoop.current.run(mode: .default, before: min(deadline, Date(timeIntervalSinceNow: 0.02))) }
    }
}

private final class CallStateRecorder: CallProtocol {
    private(set) var terminalReasons: [CallTerminationReason] = []
    private(set) var states: [CallState] = []

    func callStateUpdated(call: Call) {
        let state = call.callState
        let record = {
            self.states.append(state)
            if case let .DONE(reason) = state {
                self.terminalReasons.append(reason ?? CallTerminationReason())
            }
        }
        if Thread.isMainThread { record() } else { DispatchQueue.main.async(execute: record) }
    }
}

private final class LocalSignalingSocket: Socket {
    var onMessage: ((Message) -> Void)?
    private(set) var methods: [TelnyxRTC.Method] = []

    override func connect(signalingServer: URL) {
        self.signalingServer = signalingServer
        isConnected = true
    }

    override func disconnect(reconnect: Bool) {
        isConnected = false
    }

    override func sendMessage(message: String?) -> Bool {
        guard let text = message, let decoded = Message().decode(message: text) else { return false }
        DispatchQueue.main.async {
            if let method = decoded.method { self.methods.append(method) }
            self.onMessage?(decoded)
        }
        return true
    }
}

private final class LocalPeerDelegate: NSObject, RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
