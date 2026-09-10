import Foundation
import XCTest
@testable import TelnyxRTC

// The harness also compiles the exact app quality snapshot declaration through
// --snapshot-source. These tests exercise both production projection boundaries.
final class CallingCumulativeMediaDiagnosticsTests: XCTestCase {
    private let sender: [String: Any] = [
        "type": "outbound-rtp", "kind": "audio", "ssrc": 1114192227,
        "mediaSourceId": "chosen-source", "transportId": "chosen-transport",
        "timestamp": 123456.75, "bytesSent": 157920, "totalPacketSendDelay": 0.125,
        "codec": ["mimeType": "audio/PCMU", "clockRate": 8000, "channels": 1],
        "_uosDiagnostics": ["source": ["totalAudioEnergy": 999]],
    ]

    private func reports() -> [String: Any] {
        [
            "decoy-source": ["type": "media-source", "kind": "audio", "totalAudioEnergy": 999],
            "chosen-source": [
                "type": "media-source", "kind": "audio", "timestamp": 123450.25,
                "totalAudioEnergy": 0.75, "totalSamplesDuration": 12.5,
                "audioLevel": 0, "trackIdentifier": "private-track",
            ],
            "T01": ["type": "transport", "selectedCandidatePairId": "decoy-pair"],
            "decoy-pair": [
                "type": "candidate-pair", "nominated": true, "currentRoundTripTime": 999,
                "localCandidateId": "decoy-local", "remoteCandidateId": "decoy-remote",
            ],
            "decoy-local": ["type": "local-candidate", "protocol": "tcp", "candidateType": "relay"],
            "decoy-remote": ["type": "remote-candidate", "protocol": "tcp", "candidateType": "relay"],
            "chosen-transport": ["type": "transport", "selectedCandidatePairId": "chosen-pair"],
            "chosen-pair": [
                "type": "candidate-pair", "timestamp": 123451.5, "currentRoundTripTime": 0.625,
                "localCandidateId": "chosen-local", "remoteCandidateId": "chosen-remote",
                "address": "private-address", "usernameFragment": "private-credential",
            ],
            "chosen-local": [
                "type": "local-candidate", "protocol": "udp", "candidateType": "srflx",
                "address": "private-local-address", "url": "private-turn-url", "port": 12345,
            ],
            "chosen-remote": [
                "type": "remote-candidate", "protocol": "udp", "candidateType": "host",
                "address": "private-remote-address", "relatedAddress": "private-related-address",
            ],
        ]
    }

    private func projected(_ stats: [String: Any], reports: [String: Any]) -> [String: Any] {
        let resolved = WebRTCStatsReporter.resolvingOutboundAudioDiagnostics(stats, from: reports)
        return TelnyxPstnNativeQualitySnapshot.diagnosticMediaStats(
            inbound: nil, outbound: resolved, remoteInbound: nil
        )
    }

    private func object(_ parent: [String: Any], _ key: String) throws -> [String: Any] {
        try XCTUnwrap(parent[key] as? [String: Any], key)
    }

    private func number(_ parent: [String: Any], _ key: String) throws -> Double {
        try XCTUnwrap(parent[key] as? NSNumber, key).doubleValue
    }

    func testResolvesOnlyTheSendersSourceAndSelectedTransport() throws {
        let resolved = WebRTCStatsReporter.resolvingOutboundAudioDiagnostics(sender, from: reports())
        XCTAssertEqual(resolved["ssrc"] as? Int, 1114192227)
        XCTAssertEqual(resolved["bytesSent"] as? Int, 157920)
        let safeSDK = try object(resolved, "_uosDiagnostics")
        XCTAssertEqual(Set(safeSDK.keys), ["source", "transport"])
        let result = projected(sender, reports: reports())
        let outbound = try object(result, "outbound")
        let source = try object(outbound, "source")
        let transport = try object(outbound, "transport")
        XCTAssertEqual(try number(outbound, "ssrc"), 1114192227)
        XCTAssertEqual(try number(outbound, "totalPacketSendDelay"), 0.125)
        XCTAssertEqual(try number(source, "timestampMs"), 123450.25)
        XCTAssertEqual(try number(source, "totalAudioEnergy"), 0.75)
        XCTAssertEqual(try number(source, "totalSamplesDuration"), 12.5)
        XCTAssertEqual(try number(transport, "timestampMs"), 123451.5)
        XCTAssertEqual(try number(transport, "currentRoundTripTime"), 0.625)
        XCTAssertEqual(transport["localProtocol"] as? String, "udp")
        XCTAssertEqual(transport["remoteProtocol"] as? String, "udp")
        XCTAssertEqual(transport["localCandidateType"] as? String, "srflx")
        XCTAssertEqual(transport["remoteCandidateType"] as? String, "host")
        XCTAssertEqual(Set(source.keys), ["timestampMs", "totalAudioEnergy", "totalSamplesDuration"])
        XCTAssertEqual(Set(transport.keys), [
            "timestampMs", "currentRoundTripTime", "localProtocol", "remoteProtocol",
            "localCandidateType", "remoteCandidateType",
        ])
        for value in [safeSDK, result] {
            let text = String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
            for forbidden in ["private-", "chosen-", "decoy-", "address", "credential", "trackIdentifier", "url"] {
                XCTAssertFalse(text.contains(forbidden), forbidden)
            }
        }
    }

    func testCumulativeIntervalsSurviveAZeroInstantaneousLevel() throws {
        var earlierReports = reports()
        earlierReports["chosen-source"] = [
            "type": "media-source", "kind": "audio", "timestamp": 120950.25,
            "totalAudioEnergy": 0.25, "totalSamplesDuration": 10.0, "audioLevel": 0,
        ]
        let earlier = try object(object(projected(sender, reports: earlierReports), "outbound"), "source")
        let later = try object(object(projected(sender, reports: reports()), "outbound"), "source")
        XCTAssertEqual(try number(later, "totalAudioEnergy") - number(earlier, "totalAudioEnergy"), 0.5)
        XCTAssertEqual(try number(later, "totalSamplesDuration") - number(earlier, "totalSamplesDuration"), 2.5)
        XCTAssertEqual(try number(later, "timestampMs") - number(earlier, "timestampMs"), 2500)
    }

    func testMissingReferencesReplaceStaleValuesWithoutUsingDecoys() throws {
        let missingOrWrongReports: [[String: Any]] = [
            [:], ["chosen-source": ["type": "media-source", "kind": "video"]],
            ["chosen-transport": ["type": "candidate-pair", "selectedCandidatePairId": "decoy-pair"]],
        ]
        for changedReports in missingOrWrongReports {
            let outbound = try object(projected(sender, reports: changedReports), "outbound")
            for key in ["source", "transport"] {
                XCTAssertTrue(try object(outbound, key).values.allSatisfy { $0 is NSNull }, key)
            }
        }
        var wrongPair = reports()
        wrongPair["chosen-pair"] = ["type": "transport", "currentRoundTripTime": 99]
        let transport = try object(object(projected(sender, reports: wrongPair), "outbound"), "transport")
        XCTAssertTrue(transport.values.allSatisfy { $0 is NSNull })
    }

    func testInvalidNewScalarsAreNullAndRealZeroRemainsZero() throws {
        let invalid: [Any] = [Double.infinity, -Double.infinity, Double.nan, true, -1, 1e100, "private-value"]
        for (value, validZero) in invalid.map({ ($0, false) }) + [(0 as Any, true)] {
            var statistics = reports()
            statistics["chosen-source"] = [
                "type": "media-source", "kind": "audio", "timestamp": value,
                "totalAudioEnergy": value, "totalSamplesDuration": value,
            ]
            statistics["chosen-pair"] = ["type": "candidate-pair", "timestamp": value, "currentRoundTripTime": value]
            var sample = sender
            sample["totalPacketSendDelay"] = value
            let result = projected(sample, reports: statistics)
            let outbound = try object(result, "outbound")
            let source = try object(outbound, "source")
            let transport = try object(outbound, "transport")
            let numbers = Array(source.values) + [transport["timestampMs"]!, transport["currentRoundTripTime"]!, outbound["totalPacketSendDelay"]!]
            for number in numbers {
                if validZero { XCTAssertEqual((number as? NSNumber)?.doubleValue, 0) }
                else { XCTAssertTrue(number is NSNull) }
            }
            XCTAssertTrue(JSONSerialization.isValidJSONObject(result))
        }
    }

    func testWrongCandidateTypesAndUntrustedProjectionCannotExposePrivateStrings() throws {
        var statistics = reports()
        statistics["chosen-local"] = ["type": "remote-candidate", "protocol": "udp", "candidateType": "relay"]
        statistics["chosen-remote"] = ["type": "remote-candidate", "protocol": "private-address", "candidateType": "private-token"]
        var safe = projected(sender, reports: statistics)
        var transport = try object(object(safe, "outbound"), "transport")
        for key in ["localProtocol", "remoteProtocol", "localCandidateType", "remoteCandidateType"] {
            XCTAssertTrue(transport[key] is NSNull, key)
        }
        var untrusted = sender
        untrusted["_uosDiagnostics"] = [
            "source": ["timestamp": Double.nan, "totalAudioEnergy": true, "totalSamplesDuration": -1],
            "transport": ["localProtocol": "private-address", "remoteCandidateType": "private-token", "address": "private-address"],
        ]
        safe = TelnyxPstnNativeQualitySnapshot.diagnosticMediaStats(inbound: nil, outbound: untrusted, remoteInbound: nil)
        transport = try object(object(safe, "outbound"), "transport")
        XCTAssertTrue(transport.values.allSatisfy { $0 is NSNull })
        let source = try object(object(safe, "outbound"), "source")
        XCTAssertTrue(source.values.allSatisfy { $0 is NSNull })
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: safe), as: UTF8.self).contains("private-"))
    }

    func testCompleteEnvelopeFitsTheMediaStageServerLimit() throws {
        let maximum = 9_007_199_254_740_991.0
        var sample = sender
        for key in ["timestamp", "ssrc", "bytesReceived", "bytesSent", "packetsLost", "jitter",
                    "concealedSamples", "silentConcealedSamples", "totalSamplesReceived", "jitterBufferDelay",
                    "jitterBufferEmittedCount", "jitterBufferTargetDelay", "fractionLost", "roundTripTime", "totalPacketSendDelay"] {
            sample[key] = maximum
        }
        sample["codec"] = ["mimeType": "audio/" + String(repeating: "x", count: 58), "clockRate": 384_000, "channels": 64]
        var statistics = reports()
        statistics["chosen-source"] = ["type": "media-source", "kind": "audio", "timestamp": maximum,
                                       "totalAudioEnergy": maximum, "totalSamplesDuration": maximum]
        statistics["chosen-pair"] = ["type": "candidate-pair", "timestamp": maximum, "currentRoundTripTime": maximum,
                                     "localCandidateId": "chosen-local", "remoteCandidateId": "chosen-remote"]
        let resolved = WebRTCStatsReporter.resolvingOutboundAudioDiagnostics(sample, from: statistics)
        let media = TelnyxPstnNativeQualitySnapshot.diagnosticMediaStats(inbound: sample, outbound: resolved, remoteInbound: sample)
        let detail: [String: Any] = [
            "callId": "00000000-0000-4000-8000-000000000001", "inboundPackets": maximum, "outboundPackets": maximum,
            "inboundAudioLevel": 0.1234567890123456, "outboundAudioLevel": 0.1234567890123456,
            "jitter": 0.1234567890123456, "rtt": 0.1234567890123456, "audioSessionActive": true,
            "microphoneReady": true, "localMuted": false, "mutedByUser": false, "inputPortCount": 1,
            "localTrackCount": 1, "enabledLocalTrackCount": 1, "audioRoute": String(repeating: "x", count: 100),
            "mediaStats": media, "build": 999,
            "requestContext": ["userAgent": String(repeating: "x", count: 256), "platformHint": "ios"],
        ]
        let data = try JSONSerialization.data(withJSONObject: detail, options: [.sortedKeys])
        XCTAssertLessThanOrEqual(data.count, 4_000)
        XCTAssertTrue(try number(object(object(media, "outbound"), "source"), "totalSamplesDuration") > 0)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Complete maximum cumulative media diagnostic envelope"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
