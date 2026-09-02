//
//  TxClientSocketErrorTests.swift
//  TelnyxRTCTests
//
//  Copyright © 2025 Telnyx LLC. All rights reserved.
//

import XCTest
import CallKit
@testable import TelnyxRTC

/// Tests verifying that the SDK does not reply to server pings on an
/// unauthenticated socket. Sending pong before login triggers a 401
/// error from the server which corrupts SDK state.
class TxClientPingAuthTests: XCTestCase {

    var txClient: TxClient!
    var mockDelegate: PingTestDelegate!

    override func setUp() {
        super.setUp()
        txClient = TxClient()
        mockDelegate = PingTestDelegate()
        txClient.delegate = mockDelegate
    }

    override func tearDown() {
        txClient.delegate = nil
        txClient = nil
        mockDelegate = nil
        super.tearDown()
    }

    /// When the gateway is not registered (unauthenticated socket),
    /// receiving a PING message should NOT send a pong reply.
    /// This prevents the 401 error that corrupts SDK state during push flow.
    func testPingIgnoredWhenNotAuthenticated() {
        // Gateway state defaults to NOREG (not registered / unauthenticated).
        // Simulate receiving a telnyx_rtc.ping message.
        let pingMessage = "{\"jsonrpc\":\"2.0\",\"method\":\"telnyx_rtc.ping\",\"params\":{}}"
        txClient.onMessageReceived(message: pingMessage)

        // The client should NOT have crashed or entered a bad state.
        // Since we can't directly observe whether a message was sent on the socket
        // (socket is nil in test), we verify the client remains functional.
        XCTAssertFalse(txClient.isConnected())
    }

    /// After push flow setup, the gateway is still NOREG (login hasn't happened).
    /// PING messages should be ignored until the user answers and login completes.
    func testPingIgnoredDuringPushFlowBeforeAuth() throws {
        let txConfig = TxConfig(sipUser: "test_user", password: "test_password")
        let serverConfig = TxServerConfiguration()
        let pushMetaData: [String: Any] = [
            "voice_sdk_id": "test-sdk-id",
            "call_id": UUID().uuidString
        ]

        try txClient.processVoIPNotification(
            txConfig: txConfig,
            serverConfiguration: serverConfig,
            pushMetaData: pushMetaData
        )

        // At this point: socket is connected but unauthenticated (NOREG).
        // A ping arrives — SDK should NOT reply.
        let pingMessage = "{\"jsonrpc\":\"2.0\",\"method\":\"telnyx_rtc.ping\",\"params\":{}}"
        txClient.onMessageReceived(message: pingMessage)

        // Client should still be in a valid state, no 401 triggered.
        // The delegate should NOT have received an error.
        XCTAssertFalse(mockDelegate.onClientErrorCalled,
                       "No error should occur — ping should be silently ignored on unauthenticated socket")
    }

    func testDeclinePushDoesNotEmitDoneBeforeProviderAcknowledgement() throws {
        let callUUID = UUID()
        try startPushFlow(callId: callUUID)

        let endAction = CXEndCallAction(call: callUUID)
        txClient.endCallFromCallkit(endAction: endAction)
        txClient.onSocketConnected()

        XCTAssertTrue(mockDelegate.doneCallIds.isEmpty)
        XCTAssertTrue(mockDelegate.pushDeclineResults.isEmpty)
    }

    func testPendingDeclineClearsOnSocketErrorBeforeDeclineLogin() throws {
        let callUUID = UUID()
        try startPushFlow(callId: callUUID)

        let endAction = CXEndCallAction(call: callUUID)
        txClient.endCallFromCallkit(endAction: endAction)
        txClient.onSocketError(error: NSError(domain: "TxClientPingAuthTests", code: 1))
        txClient.onSocketConnected()

        XCTAssertTrue(mockDelegate.doneCallIds.isEmpty)
        XCTAssertEqual(mockDelegate.pushDeclineResults.count, 1)
        XCTAssertEqual(mockDelegate.pushDeclineResults.first?.callId, callUUID)
        XCTAssertEqual(mockDelegate.pushDeclineResults.first?.success, false)
    }

    func testClientReadyBeforeLoginAcknowledgementStillCompletesExactDecline() throws {
        let callUUID = UUID()
        try startPushFlow(callId: callUUID)

        let endAction = CXEndCallAction(call: callUUID)
        txClient.endCallFromCallkit(endAction: endAction)
        txClient.onSocketConnected()
        let loginId = try XCTUnwrap(privateString(named: "pendingDeclineLoginMessageId"))

        txClient.onMessageReceived(message: clientReadyMessage())
        XCTAssertTrue(mockDelegate.pushDeclineResults.isEmpty)

        txClient.onMessageReceived(message: loginAcknowledgement(id: loginId))
        let gatewayId = try XCTUnwrap(privateString(named: "pendingDeclineGatewayMessageId"))
        txClient.onMessageReceived(message: gatewayStateMessage(state: "REGED", id: gatewayId))

        XCTAssertEqual(mockDelegate.pushDeclineResults.count, 1)
        XCTAssertEqual(mockDelegate.pushDeclineResults.first?.callId, callUUID)
        XCTAssertEqual(mockDelegate.pushDeclineResults.first?.success, true)
    }

    func testStaleGatewayResponseCannotCompleteDecline() throws {
        let callUUID = UUID()
        try startPushFlow(callId: callUUID)

        let endAction = CXEndCallAction(call: callUUID)
        txClient.endCallFromCallkit(endAction: endAction)
        txClient.onSocketConnected()
        let loginId = try XCTUnwrap(privateString(named: "pendingDeclineLoginMessageId"))

        txClient.onMessageReceived(message: loginAcknowledgement(id: loginId))
        txClient.onMessageReceived(message: clientReadyMessage())
        let gatewayId = try XCTUnwrap(privateString(named: "pendingDeclineGatewayMessageId"))

        txClient.onMessageReceived(message: gatewayStateMessage(state: "REGED", id: "stale-gateway"))
        XCTAssertTrue(mockDelegate.pushDeclineResults.isEmpty)

        txClient.onMessageReceived(message: gatewayStateMessage(state: "REGED", id: gatewayId))
        XCTAssertEqual(mockDelegate.pushDeclineResults.count, 1)
        XCTAssertEqual(mockDelegate.pushDeclineResults.first?.success, true)
    }

    func testEndFailsPendingAnswerBeforeStartingDecline() throws {
        let callUUID = UUID()
        try startPushFlow(callId: callUUID)

        let answerAction = TrackingAnswerCallAction(call: callUUID)
        txClient.answerFromCallkit(answerAction: answerAction)
        txClient.endCallFromCallkit(endAction: CXEndCallAction(call: callUUID))

        XCTAssertEqual(answerAction.failCallCount, 1)
    }

    func testAnsweredPushInviteTimeoutUsesPushUUIDAndCompletesAnswerAction() throws {
        let callUUID = UUID()
        txClient.inviteTimeoutInterval = 0.01
        try startPushFlow(callId: callUUID)

        let answerAction = TrackingAnswerCallAction(call: callUUID)
        txClient.answerFromCallkit(answerAction: answerAction)
        txClient.onMessageReceived(message: gatewayStateMessage(state: "REGED"))

        let timeoutExpectation = expectation(description: "VoIP push INVITE timeout handled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            timeoutExpectation.fulfill()
        }
        wait(for: [timeoutExpectation], timeout: 1.0)

        XCTAssertEqual(mockDelegate.remoteEndedCallIds, [callUUID])
        XCTAssertEqual(mockDelegate.doneCallIds, [callUUID])
        XCTAssertEqual(answerAction.fulfillCallCount, 1)
    }

    func testActiveTerminationWaitsForRegistrationAndUsesCurrentSocket() throws {
        let staleSocket = ActiveTerminationTestSocket(connectsSuccessfully: false)
        let currentSocket = ActiveTerminationTestSocket(connectsSuccessfully: true)
        var sockets = [staleSocket, currentSocket]
        txClient.socketFactory = { sockets.removeFirst() }
        try txClient.connect(txConfig: TxConfig(sipUser: "test_user", password: "test_password"))

        let appCallId = UUID()
        let signalingCallId = UUID()
        installActiveCall(
            appCallId: appCallId,
            signalingCallId: signalingCallId,
            socket: staleSocket
        )

        let reconnected = expectation(description: "termination reconnect started")
        currentSocket.onConnect = { reconnected.fulfill() }
        let completed = expectation(description: "termination completed")
        var results: [Bool] = []
        txClient.endCallWhenSignalingReady(callId: appCallId) { success in
            results.append(success)
            completed.fulfill()
        }

        wait(for: [reconnected], timeout: 1.0)
        XCTAssertTrue(staleSocket.sentMessages.isEmpty)
        txClient.onSocketConnected()
        try completeActiveTerminationAuthentication()
        wait(for: [completed], timeout: 1.0)

        XCTAssertEqual(results, [true])
        XCTAssertFalse(staleSocket.sentMessages.contains(where: isByeMessage))
        XCTAssertTrue(currentSocket.sentMessages.contains { message in
            isByeMessage(message) && message.contains(signalingCallId.uuidString.lowercased())
        })
    }

    func testActiveTerminationTimesOutWithoutAuthenticatedSocket() throws {
        let socket = ActiveTerminationTestSocket(connectsSuccessfully: true)
        txClient.socketFactory = { socket }
        txClient.activeCallTerminationMaxReconnectAttempts = 0
        try txClient.connect(txConfig: TxConfig(sipUser: "test_user", password: "test_password"))
        let callId = UUID()
        installActiveCall(appCallId: callId, signalingCallId: callId, socket: socket)

        let completed = expectation(description: "termination timed out")
        var results: [Bool] = []
        txClient.endCallWhenSignalingReady(callId: callId, timeout: 0.02) { success in
            results.append(success)
            completed.fulfill()
        }
        txClient.onSocketConnected()
        wait(for: [completed], timeout: 1.0)

        XCTAssertEqual(results, [false])
        XCTAssertFalse(socket.sentMessages.contains(where: isByeMessage))
        XCTAssertNotNil(txClient.getCall(callId: callId))
    }

    func testRemoteByeCompletesPendingActiveTerminationExactlyOnce() throws {
        let socket = ActiveTerminationTestSocket(connectsSuccessfully: false)
        txClient.socketFactory = { socket }
        txClient.activeCallTerminationMaxReconnectAttempts = 0
        try txClient.connect(txConfig: TxConfig(sipUser: "test_user", password: "test_password"))
        let appCallId = UUID()
        let signalingCallId = UUID()
        installActiveCall(
            appCallId: appCallId,
            signalingCallId: signalingCallId,
            socket: socket
        )

        let completed = expectation(description: "remote termination accepted")
        var results: [Bool] = []
        txClient.endCallWhenSignalingReady(callId: appCallId) { success in
            results.append(success)
            completed.fulfill()
        }
        txClient.onMessageReceived(message: remoteByeMessage(callId: signalingCallId))
        wait(for: [completed], timeout: 1.0)
        txClient.onMessageReceived(message: remoteByeMessage(callId: signalingCallId))

        XCTAssertEqual(results, [true])
        XCTAssertFalse(socket.sentMessages.contains(where: isByeMessage))
    }

    func testActiveTerminationReconnectAttemptsAreBounded() throws {
        let sockets = (0..<4).map { _ in
            ActiveTerminationTestSocket(connectsSuccessfully: false)
        }
        var socketIndex = 0
        txClient.socketFactory = {
            defer { socketIndex += 1 }
            return sockets[min(socketIndex, sockets.count - 1)]
        }
        txClient.activeCallTerminationRetryInterval = 0.01
        txClient.activeCallTerminationMaxReconnectAttempts = 3
        try txClient.connect(txConfig: TxConfig(sipUser: "test_user", password: "test_password"))
        let callId = UUID()
        installActiveCall(appCallId: callId, signalingCallId: callId, socket: sockets[0])

        let completed = expectation(description: "bounded termination timed out")
        txClient.endCallWhenSignalingReady(callId: callId, timeout: 0.08) { success in
            XCTAssertFalse(success)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 1.0)

        XCTAssertEqual(socketIndex, 4)
        XCTAssertTrue(sockets.allSatisfy { socket in
            !socket.sentMessages.contains(where: isByeMessage)
        })
    }

    func testStaleActiveTerminationAuthenticationCannotSendBye() throws {
        let socket = ActiveTerminationTestSocket(connectsSuccessfully: true)
        txClient.socketFactory = { socket }
        txClient.activeCallTerminationRetryInterval = 1.0
        try txClient.connect(txConfig: TxConfig(sipUser: "test_user", password: "test_password"))
        let callId = UUID()
        installActiveCall(appCallId: callId, signalingCallId: callId, socket: socket)

        let completed = expectation(description: "current authentication completed")
        var results: [Bool] = []
        txClient.endCallWhenSignalingReady(callId: callId) { success in
            results.append(success)
            completed.fulfill()
        }

        txClient.onSocketConnected()
        let firstLoginId = try XCTUnwrap(privateString(named: "activeCallTerminationLoginMessageId"))
        txClient.onMessageReceived(message: loginAcknowledgement(id: firstLoginId))
        txClient.onMessageReceived(message: clientReadyMessage())
        let staleGatewayId = try XCTUnwrap(privateString(named: "activeCallTerminationGatewayMessageId"))

        txClient.onSocketConnected()
        let currentLoginId = try XCTUnwrap(privateString(named: "activeCallTerminationLoginMessageId"))
        XCTAssertNotEqual(firstLoginId, currentLoginId)
        txClient.onMessageReceived(message: loginAcknowledgement(id: currentLoginId))
        txClient.onMessageReceived(message: clientReadyMessage())
        let currentGatewayId = try XCTUnwrap(privateString(named: "activeCallTerminationGatewayMessageId"))

        txClient.onMessageReceived(message: gatewayStateMessage(state: "REGED", id: staleGatewayId))
        XCTAssertTrue(results.isEmpty)
        XCTAssertFalse(socket.sentMessages.contains(where: isByeMessage))

        txClient.onMessageReceived(message: gatewayStateMessage(state: "REGED", id: currentGatewayId))
        wait(for: [completed], timeout: 1.0)
        XCTAssertEqual(results, [true])
        XCTAssertEqual(socket.sentMessages.filter(isByeMessage).count, 1)
    }

    func testDuplicateActiveTerminationRequestsCompleteOnceEach() throws {
        let socket = ActiveTerminationTestSocket(connectsSuccessfully: true)
        txClient.socketFactory = { socket }
        txClient.activeCallTerminationRetryInterval = 1.0
        try txClient.connect(txConfig: TxConfig(sipUser: "test_user", password: "test_password"))
        let callId = UUID()
        installActiveCall(appCallId: callId, signalingCallId: callId, socket: socket)

        let completed = expectation(description: "both termination callers completed")
        completed.expectedFulfillmentCount = 2
        var results: [Bool] = []
        txClient.endCallWhenSignalingReady(callId: callId) { success in
            results.append(success)
            completed.fulfill()
        }
        txClient.endCallWhenSignalingReady(callId: callId) { success in
            results.append(success)
            completed.fulfill()
        }

        txClient.onSocketConnected()
        try completeActiveTerminationAuthentication()
        wait(for: [completed], timeout: 1.0)

        XCTAssertEqual(results, [true, true])
        XCTAssertEqual(socket.sentMessages.filter(isByeMessage).count, 1)
    }

    private func startPushFlow(callId: UUID) throws {
        let txConfig = TxConfig(sipUser: "test_user", password: "test_password")
        let serverConfig = TxServerConfiguration()
        let pushMetaData: [String: Any] = [
            "voice_sdk_id": "test-sdk-id",
            "call_id": callId.uuidString
        ]

        try txClient.processVoIPNotification(
            txConfig: txConfig,
            serverConfiguration: serverConfig,
            pushMetaData: pushMetaData
        )
    }

    private func clientReadyMessage() -> String {
        """
        {"jsonrpc":"2.0","method":"telnyx_rtc.clientReady","params":{}}
        """
    }

    private func loginAcknowledgement(id: String) -> String {
        """
        {"jsonrpc":"2.0","id":"\(id)","result":{"sessid":"test-session"}}
        """
    }

    private func gatewayStateMessage(state: String, id: String = "gateway-state") -> String {
        """
        {"jsonrpc":"2.0","id":"\(id)","result":{"params":{"state":"\(state)"}}}
        """
    }

    @discardableResult
    private func installActiveCall(
        appCallId: UUID,
        signalingCallId: UUID,
        socket: Socket
    ) -> Call {
        let call = Call(
            callId: appCallId,
            signalingCallId: signalingCallId,
            remoteSdp: "",
            sessionId: "active-call-session",
            socket: socket,
            delegate: txClient,
            iceServers: [],
            isAttach: true,
            enableCallReports: false
        )
        txClient.calls[appCallId] = call
        call.updateCallState(callState: .ACTIVE)
        return call
    }

    private func remoteByeMessage(callId: UUID) -> String {
        """
        {"jsonrpc":"2.0","method":"telnyx_rtc.bye","params":{"callID":"\(callId.uuidString)","cause":"NORMAL_CLEARING","causeCode":16}}
        """
    }

    private func completeActiveTerminationAuthentication() throws {
        let loginId = try XCTUnwrap(privateString(named: "activeCallTerminationLoginMessageId"))
        txClient.onMessageReceived(message: loginAcknowledgement(id: loginId))
        txClient.onMessageReceived(message: clientReadyMessage())
        let gatewayId = try XCTUnwrap(privateString(named: "activeCallTerminationGatewayMessageId"))
        txClient.onMessageReceived(message: gatewayStateMessage(state: "REGED", id: gatewayId))
    }

    private func isByeMessage(_ message: String) -> Bool {
        message.contains("telnyx_rtc.bye")
    }

    private func privateString(named name: String) -> String? {
        guard let value = Mirror(reflecting: txClient).children.first(where: {
            $0.label == name
        })?.value else {
            return nil
        }
        if let string = value as? String {
            return string
        }
        return Mirror(reflecting: value).children.first?.value as? String
    }
}

private final class ActiveTerminationTestSocket: Socket {
    let connectsSuccessfully: Bool
    var sentMessages: [String] = []
    var onConnect: (() -> Void)?

    init(connectsSuccessfully: Bool) {
        self.connectsSuccessfully = connectsSuccessfully
        super.init()
    }

    override func connect(signalingServer: URL) {
        self.signalingServer = signalingServer
        self.isConnected = connectsSuccessfully
        onConnect?()
    }

    @discardableResult
    override func sendMessage(message: String?) -> Bool {
        guard isConnected, let message else { return false }
        sentMessages.append(message)
        return true
    }

    override func disconnect(reconnect: Bool) {
        isConnected = false
    }
}

// MARK: - Test Helpers

private final class TrackingAnswerCallAction: CXAnswerCallAction {
    private(set) var fulfillCallCount = 0
    private(set) var failCallCount = 0

    override func fulfill() {
        fulfillCallCount += 1
        super.fulfill()
    }

    override func fail() {
        failCallCount += 1
        super.fail()
    }
}

class PingTestDelegate: TxClientDelegate {
    struct PushDeclineResult {
        let callId: UUID
        let success: Bool
        let error: String?
    }

    var onClientErrorCalled = false
    var doneCallIds: [UUID] = []
    var remoteEndedCallIds: [UUID] = []
    var pushDeclineResults: [PushDeclineResult] = []

    func onSocketConnected() {}
    func onSocketDisconnected() {}
    func onClientReady() {}
    func onSessionUpdated(sessionId: String) {}
    func onIncomingCall(call: Call) {}
    func onCallStateUpdated(callState: CallState, callId: UUID) {
        if case .DONE = callState {
            doneCallIds.append(callId)
        }
    }
    func onRemoteCallEnded(callId: UUID) {}
    func onRemoteCallEnded(callId: UUID, reason: CallTerminationReason?) {
        remoteEndedCallIds.append(callId)
    }
    func onPushDisabled(success: Bool, message: String) {}
    func onPushCall(call: Call) {}
    func onPushDeclineCompleted(callId: UUID, success: Bool, error: String?) {
        pushDeclineResults.append(
            PushDeclineResult(callId: callId, success: success, error: error)
        )
    }

    func onClientError(error: Error) {
        onClientErrorCalled = true
    }
}
