struct AudioOptions: OptionSet {
    let rawValue: UInt
    static let mixWithOthers = Self(rawValue: 1)
    static let duckOthers = Self(rawValue: 2)
    static let allowBluetooth = Self(rawValue: 4)
    static let defaultToSpeaker = Self(rawValue: 8)
}

final class RTCAudioSessionConfiguration {
    var categoryOptions: AudioOptions = [.allowBluetooth]
    static func webRTC() -> RTCAudioSessionConfiguration { .init() }
}

enum ConfigurationFailure: Error { case requested }

final class RTCAudioSession {
    static let instance = RTCAudioSession()
    static func sharedInstance() -> RTCAudioSession { instance }
    var options: AudioOptions = [.duckOthers, .mixWithOthers, .defaultToSpeaker]
    var events: [String] = []
    var locked = false
    var failConfiguration = false
    var deviceEnabled = false
    var active = false
    func lockForConfiguration() {
        precondition(!locked)
        locked = true
        events.append("lock")
    }
    func unlockForConfiguration() {
        precondition(locked)
        events.append("unlock")
        locked = false
    }
    func setConfiguration(_ configuration: RTCAudioSessionConfiguration) throws {
        precondition(locked)
        events.append("configure")
        if failConfiguration { throw ConfigurationFailure.requested }
        options = configuration.categoryOptions
        if options.contains(.duckOthers) { options.insert(.mixWithOthers) }
    }
}

final class TxClient {
    __ACTUAL_PREPARATION_METHOD__
}

var checks = 0
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
    checks += 1
}
let client = TxClient()
let session = RTCAudioSession.sharedInstance()
try client.prepareAudioSessionForCallKit()
check(session.options == [.allowBluetooth], "CallKit preparation must remove inherited ducking, mixing and speaker defaults")
check(session.events == ["lock", "configure", "unlock"], "Preparation is one locked configuration")
check(!session.active && !session.deviceEnabled, "Preparation does not activate audio")
check(!session.locked, "Successful preparation releases its lock")
session.events = []
try client.prepareAudioSessionForCallKit()
check(session.options == [.allowBluetooth], "Repeated preparation remains nonmixing")
check(session.events == ["lock", "configure", "unlock"], "Repeated preparation remains balanced")
session.events = []
session.failConfiguration = true
do {
    try client.prepareAudioSessionForCallKit()
    preconditionFailure("Configuration failure must reach the caller")
} catch ConfigurationFailure.requested {
    checks += 1
}
check(session.events == ["lock", "configure", "unlock"], "Failure releases the configuration lock")
check(!session.locked && !session.active && !session.deviceEnabled, "Failure cannot accept audio")
session.failConfiguration = false
try client.prepareAudioSessionForCallKit()
check(session.options == [.allowBluetooth] && !session.locked, "Preparation can recover after an error")
print("Passed \(checks) actual source CallKit preparation checks; physical routing is not exercised")
