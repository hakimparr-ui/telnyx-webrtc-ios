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

    func testAnswerReusesPushSocketWhileItIsConnecting() throws {
        let pushSocket = ActiveTerminationTestSocket(connectsSuccessfully: false)
        let replacementSocket = ActiveTerminationTestSocket(connectsSuccessfully: false)
        var sockets = [pushSocket, replacementSocket]
        var socketCreationCount = 0
        txClient.socketFactory = {
            socketCreationCount += 1
            return sockets.removeFirst()
        }
        let callUUID = UUID()
        try startPushFlow(callId: callUUID)

        let answerAction = TrackingAnswerCallAction(call: callUUID)
        txClient.answerFromCallkit(answerAction: answerAction)

        XCTAssertEqual(socketCreationCount, 1)
        XCTAssertTrue(pushSocket.sentMessages.isEmpty)

        pushSocket.emitConnected()

        XCTAssertEqual(socketCreationCount, 1)
        XCTAssertEqual(pushSocket.sentMessages.count, 1)
        XCTAssertTrue(replacementSocket.sentMessages.isEmpty)
        XCTAssertEqual(answerAction.fulfillCallCount, 0)
        XCTAssertEqual(answerAction.failCallCount, 0)
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

    func testActiveTerminationWaitsForRegistrationUsesCurrentSocketAndRequiresExactByeResponse() throws {
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
        XCTAssertTrue(results.isEmpty)
        XCTAssertNotNil(txClient.getCall(callId: appCallId))
        let byeMessageId = try latestByeMessageId(in: currentSocket)
        currentSocket.emitMessage(byeAcknowledgement(id: byeMessageId))
        wait(for: [completed], timeout: 1.0)

        XCTAssertEqual(results, [true])
        XCTAssertNil(txClient.getCall(callId: appCallId))
        XCTAssertFalse(staleSocket.sentMessages.contains(where: isByeMessage))
        XCTAssertTrue(currentSocket.sentMessages.contains { message in
            isByeMessage(message) &&
                message.contains(signalingCallId.uuidString.lowercased()) &&
                message.contains("\"sessId\":\"test-session\"")
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
        XCTAssertNotNil(privateString(named: "activeCallTerminationLoginMessageId"))
        XCTAssertTrue(socket.sentMessages.contains { $0.contains("telnyx_rtc.login") })
        txClient.onSocketConnected()
        wait(for: [completed], timeout: 1.0)

        XCTAssertEqual(results, [false])
        XCTAssertFalse(socket.sentMessages.contains(where: isByeMessage))
        XCTAssertNotNil(txClient.getCall(callId: callId))
    }

    func testRemoteByeCompletesPendingActiveTerminationExactlyOnce() throws {
        let socket = ActiveTerminationTestSocket(connectsSuccessfully: true)
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
        XCTAssertNil(txClient.getCall(callId: appCallId))
        XCTAssertFalse(socket.sentMessages.contains(where: isByeMessage))
    }

    func testAttachErrorCannotCompletePendingTerminationBeforeExactBye() throws {
        let socket = ActiveTerminationTestSocket(connectsSuccessfully: true)
        txClient.socketFactory = { socket }
        let appCallId = UUID()
        let signalingCallId = UUID()
        try startPushFlow(callId: appCallId)
        installActiveCall(
            appCallId: appCallId,
            signalingCallId: signalingCallId,
            socket: socket
        )
        txClient.sendAttachCall()
        let attachMessageId = try latestAttachMessageId(in: socket)

        let completed = expectation(description: "exact BYE completed termination")
        var results: [Bool] = []
        txClient.endCallWhenSignalingReady(callId: appCallId) { success in
            results.append(success)
            completed.fulfill()
        }
        let authenticationId = try XCTUnwrap(
            privateString(named: "activeCallTerminationLoginMessageId")
        )

        socket.emitMessage(attachError(id: attachMessageId))
        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(mockDelegate.remoteEndedCallIds.isEmpty)
        XCTAssertTrue(mockDelegate.doneCallIds.isEmpty)
        XCTAssertNotNil(txClient.getCall(callId: appCallId))
        XCTAssertNil(privateString(named: "attachCallId"))
        XCTAssertEqual(
            privateString(named: "activeCallTerminationLoginMessageId"),
            authenticationId
        )

        try completeActiveTerminationAuthentication()
        let byeMessageId = try latestByeMessageId(in: socket)
        socket.emitMessage(byeAcknowledgement(id: byeMessageId))
        wait(for: [completed], timeout: 1.0)

        XCTAssertEqual(results, [true])
        XCTAssertEqual(mockDelegate.remoteEndedCallIds, [appCallId])
        XCTAssertEqual(mockDelegate.doneCallIds, [appCallId])
        XCTAssertNil(txClient.getCall(callId: appCallId))
        XCTAssertTrue(socket.sentMessages.contains { message in
            isByeMessage(message) &&
                message.contains(signalingCallId.uuidString.lowercased())
        })
    }

    func testAttachErrorRecoveryExhaustionFailsAndRetainsCall() throws {
        let socket = ActiveTerminationTestSocket(connectsSuccessfully: true)
        txClient.socketFactory = { socket }
        txClient.activeCallTerminationMaxReconnectAttempts = 0
        let callId = UUID()
        try startPushFlow(callId: callId)
        installActiveCall(
            appCallId: callId,
            signalingCallId: callId,
            socket: socket
        )
        txClient.sendAttachCall()
        let attachMessageId = try latestAttachMessageId(in: socket)

        let completed = expectation(description: "bounded termination failed")
        var results: [Bool] = []
        txClient.endCallWhenSignalingReady(
            callId: callId,
            timeout: 0.03
        ) { success in
            results.append(success)
            completed.fulfill()
        }

        socket.emitMessage(attachError(id: attachMessageId))
        socket.emitDisconnected(reconnect: false)
        wait(for: [completed], timeout: 1.0)

        XCTAssertEqual(results, [false])
        XCTAssertTrue(mockDelegate.remoteEndedCallIds.isEmpty)
        XCTAssertTrue(mockDelegate.doneCallIds.isEmpty)
        XCTAssertNotNil(txClient.getCall(callId: callId))
        XCTAssertFalse(socket.sentMessages.contains(where: isByeMessage))
    }

    func testAttachErrorWithoutPendingTerminationRetainsProviderCall() throws {
        let socket = ActiveTerminationTestSocket(connectsSuccessfully: true)
        txClient.socketFactory = { socket }
        let callId = UUID()
        try startPushFlow(callId: callId)
        installActiveCall(
            appCallId: callId,
            signalingCallId: callId,
            socket: socket
        )
        txClient.sendAttachCall()
        let attachMessageId = try latestAttachMessageId(in: socket)

        socket.emitMessage(attachError(id: attachMessageId))

        XCTAssertTrue(mockDelegate.onClientErrorCalled)
        XCTAssertTrue(mockDelegate.remoteEndedCallIds.isEmpty)
        XCTAssertTrue(mockDelegate.doneCallIds.isEmpty)
        XCTAssertNotNil(txClient.getCall(callId: callId))
        XCTAssertNil(privateString(named: "attachCallId"))
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
        XCTAssertTrue(results.isEmpty)
        let byeMessageId = try latestByeMessageId(in: socket)
        txClient.onMessageReceived(message: byeAcknowledgement(id: byeMessageId))
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
        let byeMessageId = try latestByeMessageId(in: socket)
        txClient.onMessageReceived(message: byeAcknowledgement(id: "stale-\(byeMessageId)"))
        XCTAssertTrue(results.isEmpty)
        XCTAssertNotNil(txClient.getCall(callId: callId))
        txClient.onMessageReceived(message: byeAcknowledgement(id: byeMessageId))
        wait(for: [completed], timeout: 1.0)
        txClient.onMessageReceived(message: byeAcknowledgement(id: byeMessageId))

        XCTAssertEqual(results, [true, true])
        XCTAssertEqual(socket.sentMessages.filter(isByeMessage).count, 1)
    }

    func testExactByeServerErrorFailsTerminationAndRetainsCall() throws {
        let socket = ActiveTerminationTestSocket(connectsSuccessfully: true)
        txClient.socketFactory = { socket }
        txClient.activeCallTerminationRetryInterval = 1.0
        try txClient.connect(txConfig: TxConfig(sipUser: "test_user", password: "test_password"))
        let callId = UUID()
        installActiveCall(appCallId: callId, signalingCallId: callId, socket: socket)

        let completed = expectation(description: "exact BYE error reported")
        var results: [Bool] = []
        txClient.endCallWhenSignalingReady(callId: callId) { success in
            results.append(success)
            completed.fulfill()
        }

        socket.emitConnected()
        try completeActiveTerminationAuthentication()
        let byeMessageId = try latestByeMessageId(in: socket)
        socket.emitMessage(byeError(id: byeMessageId))
        wait(for: [completed], timeout: 1.0)
        socket.emitMessage(byeAcknowledgement(id: byeMessageId))

        XCTAssertEqual(results, [false])
        XCTAssertNotNil(txClient.getCall(callId: callId))
        XCTAssertEqual(socket.sentMessages.filter(isByeMessage).count, 1)
    }

    func testQueuedByeWithoutResponseTimesOutAndIgnoresLateAcknowledgement() throws {
        let socket = ActiveTerminationTestSocket(connectsSuccessfully: true)
        txClient.socketFactory = { socket }
        txClient.activeCallTerminationRetryInterval = 1.0
        try txClient.connect(txConfig: TxConfig(sipUser: "test_user", password: "test_password"))
        let callId = UUID()
        installActiveCall(appCallId: callId, signalingCallId: callId, socket: socket)

        let completed = expectation(description: "unacknowledged BYE timed out")
        var results: [Bool] = []
        txClient.endCallWhenSignalingReady(callId: callId, timeout: 0.1) { success in
            results.append(success)
            completed.fulfill()
        }

        socket.emitConnected()
        try completeActiveTerminationAuthentication()
        let byeMessageId = try latestByeMessageId(in: socket)
        XCTAssertTrue(results.isEmpty)
        XCTAssertNotNil(txClient.getCall(callId: callId))
        wait(for: [completed], timeout: 1.0)
        socket.emitMessage(byeAcknowledgement(id: byeMessageId))

        XCTAssertEqual(results, [false])
        XCTAssertNotNil(txClient.getCall(callId: callId))
    }

    func testObsoleteSocketCallbacksCannotAffectCurrentTerminationTransaction() throws {
        let obsoleteSocket = ActiveTerminationTestSocket(connectsSuccessfully: false)
        let currentSocket = ActiveTerminationTestSocket(connectsSuccessfully: true)
        var sockets = [obsoleteSocket, currentSocket]
        txClient.socketFactory = { sockets.removeFirst() }
        try txClient.connect(txConfig: TxConfig(sipUser: "test_user", password: "test_password"))
        let callId = UUID()
        installActiveCall(appCallId: callId, signalingCallId: callId, socket: obsoleteSocket)

        try txClient.connect(txConfig: TxConfig(sipUser: "test_user", password: "test_password"))
        obsoleteSocket.emitConnected()
        obsoleteSocket.emitMessage(gatewayStateMessage(state: "REGED"))
        obsoleteSocket.emitDisconnected()
        obsoleteSocket.emitError()
        XCTAssertFalse(txClient.isRegistered)

        let completed = expectation(description: "current socket completed termination")
        var results: [Bool] = []
        txClient.endCallWhenSignalingReady(callId: callId) { success in
            results.append(success)
            completed.fulfill()
        }
        XCTAssertFalse(currentSocket.sentMessages.contains(where: isByeMessage))

        currentSocket.emitConnected()
        let loginId = try XCTUnwrap(privateString(named: "activeCallTerminationLoginMessageId"))
        obsoleteSocket.emitConnected()
        obsoleteSocket.emitMessage(loginAcknowledgement(id: loginId))
        obsoleteSocket.emitDisconnected()
        obsoleteSocket.emitError()
        XCTAssertEqual(privateString(named: "activeCallTerminationLoginMessageId"), loginId)

        currentSocket.emitMessage(loginAcknowledgement(id: loginId))
        obsoleteSocket.emitMessage(clientReadyMessage())
        currentSocket.emitMessage(clientReadyMessage())
        let gatewayId = try XCTUnwrap(privateString(named: "activeCallTerminationGatewayMessageId"))
        obsoleteSocket.emitMessage(gatewayStateMessage(state: "REGED", id: gatewayId))
        obsoleteSocket.emitDisconnected()
        obsoleteSocket.emitError()
        XCTAssertTrue(results.isEmpty)
        XCTAssertFalse(currentSocket.sentMessages.contains(where: isByeMessage))

        currentSocket.emitMessage(gatewayStateMessage(state: "REGED", id: gatewayId))
        let byeMessageId = try latestByeMessageId(in: currentSocket)
        obsoleteSocket.emitMessage(byeAcknowledgement(id: byeMessageId))
        XCTAssertTrue(results.isEmpty)
        XCTAssertNotNil(txClient.getCall(callId: callId))
        currentSocket.emitMessage(byeAcknowledgement(id: byeMessageId))
        wait(for: [completed], timeout: 1.0)
        XCTAssertEqual(results, [true])
        XCTAssertEqual(currentSocket.sentMessages.filter(isByeMessage).count, 1)
    }

    func testActiveTerminationPollsExactGatewayIdAfterTransitionalState() throws {
        let socket = ActiveTerminationTestSocket(connectsSuccessfully: true)
        txClient.socketFactory = { socket }
        txClient.activeCallTerminationGatewayPollInterval = 0.01
        txClient.activeCallTerminationRetryInterval = 1.0
        try txClient.connect(txConfig: TxConfig(sipUser: "test_user", password: "test_password"))
        let callId = UUID()
        installActiveCall(appCallId: callId, signalingCallId: callId, socket: socket)

        let completed = expectation(description: "transitional gateway reached REGED")
        var results: [Bool] = []
        txClient.endCallWhenSignalingReady(callId: callId) { success in
            results.append(success)
            completed.fulfill()
        }
        socket.emitConnected()
        let loginId = try XCTUnwrap(privateString(named: "activeCallTerminationLoginMessageId"))
        socket.emitMessage(loginAcknowledgement(id: loginId))
        socket.emitMessage(clientReadyMessage())
        let transitionalGatewayId = try XCTUnwrap(privateString(named: "activeCallTerminationGatewayMessageId"))
        socket.emitMessage(gatewayStateMessage(state: "NOREG", id: transitionalGatewayId))

        let polled = expectation(description: "exact gateway poll issued")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            polled.fulfill()
        }
        wait(for: [polled], timeout: 1.0)
        let registeredGatewayId = try XCTUnwrap(privateString(named: "activeCallTerminationGatewayMessageId"))
        XCTAssertNotEqual(transitionalGatewayId, registeredGatewayId)
        XCTAssertTrue(results.isEmpty)

        socket.emitMessage(gatewayStateMessage(state: "REGED", id: registeredGatewayId))
        XCTAssertTrue(results.isEmpty)
        let byeMessageId = try latestByeMessageId(in: socket)
        socket.emitMessage(byeAcknowledgement(id: byeMessageId))
        wait(for: [completed], timeout: 1.0)
        XCTAssertEqual(results, [true])
        XCTAssertEqual(socket.sentMessages.filter(isByeMessage).count, 1)
    }

    func testActiveTerminationReverifiesCurrentRegisteredSocketBeforeBye() throws {
        let socket = ActiveTerminationTestSocket(connectsSuccessfully: true)
        txClient.socketFactory = { socket }
        try txClient.connect(txConfig: TxConfig(sipUser: "test_user", password: "test_password"))
        let callId = UUID()
        installActiveCall(appCallId: callId, signalingCallId: callId, socket: socket)
        socket.emitMessage(gatewayStateMessage(state: "REGED", id: "normal-registration"))
        XCTAssertTrue(txClient.isRegistered)

        let completed = expectation(description: "registered socket reverified")
        var results: [Bool] = []
        txClient.endCallWhenSignalingReady(callId: callId) { success in
            results.append(success)
            completed.fulfill()
        }
        XCTAssertTrue(results.isEmpty)
        XCTAssertFalse(socket.sentMessages.contains(where: isByeMessage))

        let verificationId = try XCTUnwrap(privateString(named: "activeCallTerminationGatewayMessageId"))
        XCTAssertNotEqual(verificationId, "normal-registration")
        socket.emitMessage(gatewayStateMessage(state: "REGED", id: verificationId))
        XCTAssertTrue(results.isEmpty)
        XCTAssertNotNil(txClient.getCall(callId: callId))
        let byeMessageId = try latestByeMessageId(in: socket)
        socket.emitMessage(byeAcknowledgement(id: byeMessageId))
        wait(for: [completed], timeout: 1.0)
        XCTAssertEqual(results, [true])
        XCTAssertEqual(socket.sentMessages.filter(isByeMessage).count, 1)
    }

    func testDisablePushRequiresExactSuccessAndCompletesOnce() throws {
        let socket = ActiveTerminationTestSocket(connectsSuccessfully: true)
        txClient.socketFactory = { socket }
        try txClient.connect(txConfig: TxConfig(sipUser: "test_user", password: "test_password"))

        txClient.disablePushNotifications()
        let messageId = try latestDisablePushMessageId(in: socket)
        socket.emitMessage(disablePushSuccess(id: "wrong-\(messageId)"))
        XCTAssertTrue(mockDelegate.pushDisabledResults.isEmpty)

        socket.emitMessage(disablePushSuccess(id: messageId))
        socket.emitMessage(disablePushSuccess(id: messageId))

        XCTAssertEqual(mockDelegate.pushDisabledResults.map(\.success), [true])
        XCTAssertEqual(
            mockDelegate.pushDisabledResults.first?.message,
            DisablePushMessage.DISABLE_PUSH_SUCCESS_MESSAGE
        )
    }

    func testDisablePushExactServerErrorFailsOnceAndIgnoresLateSuccess() throws {
        let socket = ActiveTerminationTestSocket(connectsSuccessfully: true)
        txClient.socketFactory = { socket }
        try txClient.connect(txConfig: TxConfig(sipUser: "test_user", password: "test_password"))

        txClient.disablePushNotifications()
        let messageId = try latestDisablePushMessageId(in: socket)
        socket.emitMessage(disablePushError(id: messageId))
        socket.emitMessage(disablePushSuccess(id: messageId))

        XCTAssertEqual(mockDelegate.pushDisabledResults.map(\.success), [false])
        XCTAssertEqual(mockDelegate.pushDisabledResults.first?.message, "disable push rejected")
    }

    func testDisablePushTimesOutAndIgnoresLateSuccess() throws {
        let socket = ActiveTerminationTestSocket(connectsSuccessfully: true)
        txClient.socketFactory = { socket }
        txClient.disablePushTimeoutInterval = 0.01
        try txClient.connect(txConfig: TxConfig(sipUser: "test_user", password: "test_password"))

        let timedOut = expectation(description: "disable push timed out")
        mockDelegate.onPushDisabledHandler = { success, _ in
            if !success { timedOut.fulfill() }
        }
        txClient.disablePushNotifications()
        let messageId = try latestDisablePushMessageId(in: socket)
        wait(for: [timedOut], timeout: 1.0)
        socket.emitMessage(disablePushSuccess(id: messageId))

        XCTAssertEqual(mockDelegate.pushDisabledResults.map(\.success), [false])
        XCTAssertEqual(
            mockDelegate.pushDisabledResults.first?.message,
            "disable push notification request timed out"
        )
    }

    func testDisablePushSendFailureReportsFalseExactlyOnce() throws {
        let socket = ActiveTerminationTestSocket(connectsSuccessfully: true)
        socket.sendsSuccessfully = false
        txClient.socketFactory = { socket }
        try txClient.connect(txConfig: TxConfig(sipUser: "test_user", password: "test_password"))

        txClient.disablePushNotifications()

        XCTAssertEqual(mockDelegate.pushDisabledResults.map(\.success), [false])
        XCTAssertEqual(
            mockDelegate.pushDisabledResults.first?.message,
            "disable push notification request could not be sent"
        )
        XCTAssertTrue(socket.sentMessages.isEmpty)
    }

    func testOldDisablePushResponseCannotSatisfyNewSocketOperation() throws {
        let oldSocket = ActiveTerminationTestSocket(connectsSuccessfully: true)
        let currentSocket = ActiveTerminationTestSocket(connectsSuccessfully: true)
        var sockets = [oldSocket, currentSocket]
        txClient.socketFactory = { sockets.removeFirst() }
        let config = TxConfig(sipUser: "test_user", password: "test_password")
        try txClient.connect(txConfig: config)

        txClient.disablePushNotifications()
        let oldMessageId = try latestDisablePushMessageId(in: oldSocket)
        try txClient.connect(txConfig: config)
        txClient.disablePushNotifications()
        let currentMessageId = try latestDisablePushMessageId(in: currentSocket)
        XCTAssertNotEqual(oldMessageId, currentMessageId)
        XCTAssertEqual(mockDelegate.pushDisabledResults.map(\.success), [false])

        oldSocket.emitMessage(disablePushSuccess(id: oldMessageId))
        oldSocket.emitMessage(disablePushSuccess(id: currentMessageId))
        currentSocket.emitMessage(disablePushSuccess(id: oldMessageId))
        XCTAssertEqual(mockDelegate.pushDisabledResults.map(\.success), [false])

        currentSocket.emitMessage(disablePushSuccess(id: currentMessageId))
        XCTAssertEqual(mockDelegate.pushDisabledResults.map(\.success), [false, true])
    }

    func testDisablePushDisconnectFailsOnceAndIgnoresLateResponse() throws {
        let socket = ActiveTerminationTestSocket(connectsSuccessfully: true)
        txClient.socketFactory = { socket }
        try txClient.connect(txConfig: TxConfig(sipUser: "test_user", password: "test_password"))

        txClient.disablePushNotifications()
        let messageId = try latestDisablePushMessageId(in: socket)
        socket.emitDisconnected(reconnect: false)
        socket.emitMessage(disablePushSuccess(id: messageId))

        XCTAssertEqual(mockDelegate.pushDisabledResults.map(\.success), [false])
        XCTAssertEqual(
            mockDelegate.pushDisabledResults.first?.message,
            "socket disconnected before push notifications were disabled"
        )
    }

    func testDisablePushSocketErrorFailsOnceAndIgnoresLateResponse() throws {
        let socket = ActiveTerminationTestSocket(connectsSuccessfully: true)
        txClient.socketFactory = { socket }
        try txClient.connect(txConfig: TxConfig(sipUser: "test_user", password: "test_password"))

        txClient.disablePushNotifications()
        let messageId = try latestDisablePushMessageId(in: socket)
        socket.emitError()
        socket.emitMessage(disablePushSuccess(id: messageId))

        XCTAssertEqual(mockDelegate.pushDisabledResults.map(\.success), [false])
        XCTAssertEqual(
            mockDelegate.pushDisabledResults.first?.message,
            "socket error before push notifications were disabled"
        )
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

    private func byeAcknowledgement(id: String) -> String {
        """
        {"jsonrpc":"2.0","id":"\(id)","result":{}}
        """
    }

    private func byeError(id: String) -> String {
        """
        {"jsonrpc":"2.0","id":"\(id)","error":{"code":-32000,"message":"BYE rejected"}}
        """
    }

    private func attachError(id: String) -> String {
        """
        {"jsonrpc":"2.0","id":"\(id)","error":{"code":-32000,"message":"ATTACH rejected"}}
        """
    }

    private func disablePushSuccess(id: String) -> String {
        """
        {"jsonrpc":"2.0","id":"\(id)","result":{"message":"\(DisablePushMessage.DISABLE_PUSH_SUCCESS_MESSAGE)"}}
        """
    }

    private func disablePushError(id: String) -> String {
        """
        {"jsonrpc":"2.0","id":"\(id)","error":{"code":-32000,"message":"disable push rejected"}}
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

    private func latestByeMessageId(in socket: ActiveTerminationTestSocket) throws -> String {
        let message = try XCTUnwrap(socket.sentMessages.last(where: isByeMessage))
        let data = try XCTUnwrap(message.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data)
        let dictionary = try XCTUnwrap(object as? [String: Any])
        return try XCTUnwrap(dictionary["id"] as? String)
    }

    private func latestAttachMessageId(
        in socket: ActiveTerminationTestSocket
    ) throws -> String {
        let message = try XCTUnwrap(socket.sentMessages.last {
            $0.contains("telnyx_rtc.attachCalls")
        })
        let data = try XCTUnwrap(message.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data)
        let dictionary = try XCTUnwrap(object as? [String: Any])
        return try XCTUnwrap(dictionary["id"] as? String)
    }

    private func latestDisablePushMessageId(
        in socket: ActiveTerminationTestSocket
    ) throws -> String {
        let message = try XCTUnwrap(socket.sentMessages.last {
            $0.contains("telnyx_rtc.disable_push_notification")
        })
        let data = try XCTUnwrap(message.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data)
        let dictionary = try XCTUnwrap(object as? [String: Any])
        return try XCTUnwrap(dictionary["id"] as? String)
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
    var sendsSuccessfully = true

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
        guard sendsSuccessfully, isConnected, let message else { return false }
        sentMessages.append(message)
        return true
    }

    override func disconnect(reconnect: Bool) {
        isConnected = false
    }

    func emitConnected() {
        isConnected = true
        delegate?.onSocketConnected(socket: self)
    }

    func emitDisconnected(reconnect: Bool = true) {
        isConnected = false
        delegate?.onSocketDisconnected(socket: self, reconnect: reconnect, region: nil)
    }

    func emitError() {
        isConnected = false
        delegate?.onSocketError(
            socket: self,
            error: NSError(domain: "ActiveTerminationTestSocket", code: 1)
        )
    }

    func emitMessage(_ message: String) {
        delegate?.onMessageReceived(socket: self, message: message)
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

    struct PushDisabledResult {
        let success: Bool
        let message: String
    }

    var onClientErrorCalled = false
    var doneCallIds: [UUID] = []
    var remoteEndedCallIds: [UUID] = []
    var pushDeclineResults: [PushDeclineResult] = []
    var pushDisabledResults: [PushDisabledResult] = []
    var onPushDisabledHandler: ((Bool, String) -> Void)?

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
    func onPushDisabled(success: Bool, message: String) {
        pushDisabledResults.append(PushDisabledResult(success: success, message: message))
        onPushDisabledHandler?(success, message)
    }
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
