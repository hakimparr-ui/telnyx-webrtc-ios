var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fatalError(message) }
    checks += 1
}
func installedCall() -> (TxClient, Call, UUID) {
    let client = TxClient()
    let call = Call()
    let id = call.callInfo!.callId
    client.calls[id] = call
    return (client, call, id)
}

let (client, incoming, id) = installedCall()
check(client.stopLocalMediaForUnansweredDecline(callId: id, expectedCall: incoming), "passive invite decline accepted")
check(client.hasStoppedLocalMediaForUnansweredDecline(callId: id, expectedCall: incoming), "exact readback")
check(client.calls[id] === incoming, "provider call custody retained")
check(incoming.callState == .NEW && !incoming.terminationStarted, "provider BYE remains independent")
check(incoming.toneStopCount == 2, "local tones stopped")
incoming.answer()
incoming.reattach()
check(incoming.peer == nil && incoming.peerCreateCount == 0, "late answer and attach cannot create media")
incoming.updateCallState(callState: .ACTIVE)
check(incoming.callState == .NEW, "late active cannot revive local call")
check(client.stopLocalMediaForUnansweredDecline(callId: id, expectedCall: incoming), "duplicate decline is idempotent")
check(incoming.toneStopCount == 2, "duplicate does not repeat local teardown")
client.deliverIncoming(callId: id)
check(client.createdCallCount == 0, "late matching app UUID invite fenced")
client.deliverIncoming(callId: incoming.signalingCallId)
check(client.createdCallCount == 0, "late signaling alias fenced before mapping")
client.socketToAppCallId[incoming.signalingCallId] = id
client.deliverIncoming(callId: incoming.signalingCallId)
check(client.createdCallCount == 0, "late mapped attach fenced")
client.isCallFromPush = true
client.currentCallId = UUID()
client.deliverIncoming(callId: incoming.signalingCallId)
check(client.createdCallCount == 0, "another push cannot revive declined signaling call")
let otherPushId = client.currentCallId
client.processPush(pushMetaData: ["call_id": id.uuidString])
client.processPush(pushMetaData: ["call_id": incoming.signalingCallId.uuidString])
check(client.processedPushCount == 0, "duplicate declined push fenced for app and signaling UUIDs")
check(client.calls[id] === incoming && client.currentCallId == otherPushId, "duplicate push preserves exact provider object and another pending push")
client.processPush(pushMetaData: ["call_id": UUID().uuidString])
check(client.processedPushCount == 1, "unrelated push can proceed")
client.isCallFromPush = false
client.socketToAppCallId.removeAll()
client.calls.removeValue(forKey: id)
client.deliverIncoming(callId: incoming.signalingCallId)
check(client.createdCallCount == 0, "terminal provider cleanup does not discard late event fence")
check(!client.hasStoppedLocalMediaForUnansweredDecline(callId: id, expectedCall: incoming), "removed object readback refused")
client.deliverIncoming(callId: UUID())
check(client.createdCallCount == 1, "different call unaffected")

let protectedStates: [CallState] = [.CONNECTING, .ACTIVE, .HELD, .RECONNECTING(reason: "network"), .DROPPED(reason: "network"), .DONE()]
for state in protectedStates {
    let (owner, call, uuid) = installedCall()
    call.callState = state
    check(!owner.stopLocalMediaForUnansweredDecline(callId: uuid, expectedCall: call), "nonringing call refused")
    check(!call.localDeclineMediaStopped && call.toneStopCount == 0, "refusal leaves call alone")
}
let protectedDirections: [CallDirection] = [.OUTBOUND, .ATTACH]
for direction in protectedDirections {
    let (owner, call, uuid) = installedCall()
    call.direction = direction
    check(!owner.stopLocalMediaForUnansweredDecline(callId: uuid, expectedCall: call), "nonincoming call refused")
}
let (ringOwner, ringing, ringId) = installedCall()
ringing.callState = .RINGING
check(ringOwner.stopLocalMediaForUnansweredDecline(callId: ringId, expectedCall: ringing), "ringing passive invite accepted")
let (placeholderOwner, placeholder, placeholderId) = installedCall()
placeholder.remoteSdp = ""
check(!placeholderOwner.stopLocalMediaForUnansweredDecline(callId: placeholderId, expectedCall: placeholder), "placeholder remains available for passive discovery")
placeholder.remoteSdp = nil
check(!placeholderOwner.stopLocalMediaForUnansweredDecline(callId: placeholderId, expectedCall: placeholder), "missing invite refused")
let (peerOwner, media, mediaId) = installedCall()
media.peer = Peer()
check(!peerOwner.stopLocalMediaForUnansweredDecline(callId: mediaId, expectedCall: media), "existing media refused")
check(media.peer != nil, "existing media untouched")
let (answerOwner, answered, answeredId) = installedCall()
answered.answer()
check(answered.peerCreateCount == 1, "genuine answer still creates media")
check(!answerOwner.stopLocalMediaForUnansweredDecline(callId: answeredId, expectedCall: answered), "answer in flight refused")
let (historyOwner, historical, historyId) = installedCall()
historical.updateCallState(callState: .ACTIVE)
historical.updateCallState(callState: .RINGING)
check(!historyOwner.stopLocalMediaForUnansweredDecline(callId: historyId, expectedCall: historical), "ever active call refused even after stale ringing")
let (replacementOwner, original, replacementId) = installedCall()
let replacement = Call(id: replacementId)
replacementOwner.calls[replacementId] = replacement
check(!replacementOwner.stopLocalMediaForUnansweredDecline(callId: replacementId, expectedCall: original), "replaced call generation refused")
check(!replacement.localDeclineMediaStopped, "replacement remains untouched")
check(!replacementOwner.stopLocalMediaForUnansweredDecline(callId: UUID(), expectedCall: replacement), "wrong UUID refused")
let (terminalOwner, terminating, terminalId) = installedCall()
terminating.terminationStarted = true
check(!terminalOwner.stopLocalMediaForUnansweredDecline(callId: terminalId, expectedCall: terminating), "already terminating call refused")
let (activeOwner, active, activeId) = installedCall()
active.updateCallState(callState: .ACTIVE)
let passive = Call()
let passiveId = passive.callInfo!.callId
activeOwner.calls[passiveId] = passive
check(activeOwner.stopLocalMediaForUnansweredDecline(callId: passiveId, expectedCall: passive), "passive decline beside active call")
check(active.callState == .ACTIVE && !active.localDeclineMediaStopped && activeOwner.calls[activeId] === active, "other active call preserved")
passive.updateCallState(callState: .DONE())
check(passive.callState == .DONE(), "provider acknowledgment can finish terminal cleanup")
print("declined invite media fence: \(checks) passed")
