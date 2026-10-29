from pathlib import Path
import hashlib
import json
import sys

root = Path(__file__).resolve().parents[1]
call_path = root / 'TelnyxRTC/Telnyx/WebRTC/Call.swift'
client_path = root / 'TelnyxRTC/Telnyx/TxClient.swift'
call = call_path.read_text()
client = client_path.read_text()

def declaration(source, signature):
    start = source.index(signature)
    opening = source.index('{', start)
    depth = 0
    for pos in range(opening, len(source)):
        if source[pos] == '{':
            depth += 1
        elif source[pos] == '}':
            depth -= 1
            if depth == 0:
                return source[start:pos + 1]
    raise ValueError(signature)

def body(source, signature):
    value = declaration(source, signature)
    return value[value.index('{') + 1:value.rfind('}')]

stop = declaration(call, '    internal func stopLocalMediaForUnansweredDecline()')
readback = declaration(call, '    internal var hasStoppedLocalMediaForUnansweredDecline: Bool')
stop_client = declaration(client, '    public func stopLocalMediaForUnansweredDecline(')
read_client = declaration(client, '    public func hasStoppedLocalMediaForUnansweredDecline(')
fence = declaration(client, '    private func isLocallyDeclinedIncomingCall(')
answer = body(call, '    public func answer(')
answer_guard = answer[:answer.index('        self.answerPreferredCodecs')]
reattach = body(call, '    internal func acceptReAttach(')
reattach_guard = reattach[:reattach.index('        if let preferredCodecs')]
state = body(call, '    internal func updateCallState(')
state_guard = state[:state.index('        Logger.log.i')]
state_record = state[state.index('        self.callState = callState'):state.index('        callReportCollector?')]
incoming = body(client, '    private func createIncomingCall(')
incoming_guard = incoming[:incoming.index('        let passiveInvite')]
push = body(client, '    public func processVoIPNotification(')
push_guard = push[:push.index('        let rtc_id')]
assert push.index('isLocallyDeclinedIncomingCall(') < push.index('FileLogger.isCallFromPush') < push.index('self.calls[callUUID] = Call(')
assert incoming_guard.index('isLocallyDeclinedIncomingCall(') < len(incoming_guard)
assert incoming.index('isLocallyDeclinedIncomingCall(') < incoming.index('self.calls.removeValue') < incoming.index('let call = Call(') < incoming.index('call.acceptReAttach(')
assert 'queueHangup' not in stop and 'endCall(' not in stop and 'terminationStarted = true' not in stop
assert 'locallyDeclinedIncomingCallIds.remove' not in client
assert call.count('self.peer = Peer(') == 3
assert 'answerStarted = true' in answer_guard and 'answerStarted = true' in reattach_guard
assert 'localDeclineMediaStopped' in body(call, '    private func playRingtone(')
assert 'localDeclineMediaStopped' in body(call, '    private func playRingbackTone(')

harness = '''import Foundation
public enum CallState: Equatable {
    case NEW, RINGING, CONNECTING, ACTIVE, HELD
    case RECONNECTING(reason: String), DROPPED(reason: String)
    case DONE(reason: String? = nil)
}
public enum CallDirection { case INBOUND, OUTBOUND, ATTACH }
public final class Peer {}
public final class Socket {}
public struct TxCallInfo { public var callId: UUID }
public final class Logger {
    public static let log = Logger()
    public func i(message: String) {}
}
public final class Call {
    var direction: CallDirection = .INBOUND
    var callState: CallState = .NEW
    var peer: Peer?
    var terminationStarted = false
    var localDeclineMediaStopped = false
    var answerStarted = false
    var hasEnteredMediaState = false
    var remoteSdp: String? = "actual invite"
    var callInfo: TxCallInfo?
    var signalingCallId: UUID
    let terminationLock = NSRecursiveLock()
    var toneStopCount = 0
    var peerCreateCount = 0
    init(id: UUID = UUID(), signalingId: UUID = UUID()) {
        callInfo = TxCallInfo(callId: id)
        signalingCallId = signalingId
    }
    func stopRingtone() { toneStopCount += 1 }
    func stopRingbackTone() { toneStopCount += 1 }
'''+stop+'\n'+readback+'''
    func answer() {
'''+answer_guard+'''        peerCreateCount += 1
        peer = Peer()
    }
    func reattach() {
'''+reattach_guard+'''        peerCreateCount += 1
        peer = Peer()
    }
    func updateCallState(callState: CallState) {
'''+state_guard+state_record+'''        terminationLock.unlock()
    }
}
public final class TxClient {
    var calls: [UUID: Call] = [:]
    var locallyDeclinedIncomingCallIds: Set<UUID> = []
    var socketToAppCallId: [UUID: UUID] = [:]
    var sessionId: String? = "session"
    var socket: Socket? = Socket()
    var isCallFromPush = false
    var currentCallId = UUID()
    var createdCallCount = 0
    var processedPushCount = 0
'''+stop_client+'\n'+read_client+'\n'+fence+'''
    func deliverIncoming(callId: UUID) {
'''+incoming_guard+'''        createdCallCount += 1
    }
    func processPush(pushMetaData: [String: Any]) {
'''+push_guard+'''        processedPushCount += 1
    }
}
'''
output = Path(sys.argv[1])
output.write_text(harness + (root / 'scripts/test-declined-invite-media-fence.swift').read_text())
print(json.dumps({'generated': str(output), 'sourceSha256': {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in [call_path, client_path]}, 'scope': 'actual extracted decline functions and answer, state and incoming entry guards; no WebRTC runtime proof'}))
