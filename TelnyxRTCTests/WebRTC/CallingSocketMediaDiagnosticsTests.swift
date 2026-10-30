import Foundation
import XCTest
@testable import TelnyxRTC

final class CallingSocketMediaDiagnosticsTests: XCTestCase {
    private let fields = ["packetsSent", "bytesSent", "packetsReceived", "bytesReceived",
                          "packetsDiscardedOnSend", "bytesDiscardedOnSend"]

    private func projection(_ values: [String: Any], selected: String = "actual") throws -> [String: Any] {
        var actual = values
        actual["type"] = "candidate-pair"
        actual["address"] = "private-address"
        actual["usernameFragment"] = "private-secret"
        let resolved = WebRTCStatsReporter.resolvingOutboundAudioDiagnostics([
            "ssrc": 42, "transportId": "transport",
        ], from: [
            "transport": ["type": "transport", "selectedCandidatePairId": selected],
            "actual": actual,
            "decoy": ["type": "candidate-pair", "nominated": true,
                      "packetsSent": 999, "packetsDiscardedOnSend": 999],
        ])
        let result = TelnyxPstnNativeQualitySnapshot.diagnosticMediaStats(
            inbound: nil, outbound: resolved, remoteInbound: nil
        )
        let outbound = try XCTUnwrap(result["outbound"] as? [String: Any])
        let transport = try XCTUnwrap(outbound["transport"] as? [String: Any])
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
        XCTAssertFalse(encoded.contains("private-"))
        XCTAssertFalse(encoded.contains("actual"))
        XCTAssertFalse(encoded.contains("decoy"))
        return transport
    }

    func testSocketCountersFollowSelectedPairAndKeepRealZero() throws {
        let values: [String: Any] = ["packetsSent": 100, "bytesSent": 16000,
                                   "packetsReceived": 70, "bytesReceived": 11200,
                                   "packetsDiscardedOnSend": 3, "bytesDiscardedOnSend": 480]
        let actual = try projection(values)
        for field in fields {
            XCTAssertEqual((actual[field] as? NSNumber)?.int64Value, (values[field] as? NSNumber)?.int64Value, field)
        }
        let zero = try projection(Dictionary(uniqueKeysWithValues: fields.map { ($0, 0 as Any) }))
        for field in fields { XCTAssertEqual((zero[field] as? NSNumber)?.intValue, 0, field) }
    }

    func testUnavailableAndInvalidCountersNeverBecomeZero() throws {
        let invalid: [Any] = [-1, 0.5, true, Double.nan, Double.infinity, 9_007_199_254_740_992.0, "3"]
        for value in invalid {
            let result = try projection(Dictionary(uniqueKeysWithValues: fields.map { ($0, value) }))
            for field in fields { XCTAssertTrue(result[field] is NSNull, field) }
        }
        for result in [try projection([:]), try projection(["packetsSent": 12], selected: "gone")] {
            for field in fields { XCTAssertTrue(result[field] is NSNull, field) }
        }
    }

    func testPairChangeNeverReusesPreviousCounterValues() throws {
        let lost = try projection(["packetsSent": 100, "packetsDiscardedOnSend": 7])
        let replacement = try projection(["packetsSent": 2, "packetsDiscardedOnSend": 0])
        XCTAssertEqual((lost["packetsDiscardedOnSend"] as? NSNumber)?.intValue, 7)
        XCTAssertEqual((replacement["packetsDiscardedOnSend"] as? NSNumber)?.intValue, 0)
        XCTAssertEqual((replacement["packetsSent"] as? NSNumber)?.intValue, 2)
    }

    func testReportCountersRequireMatchingSenderAndPreserveMissingFields() throws {
        func report(_ remote: [String: Any], sender: [String: Any]?) throws -> [String: Any] {
            let projected = TelnyxPstnNativeQualitySnapshot.diagnosticMediaStats(
                inbound: nil, outbound: sender, remoteInbound: remote
            )
            return try XCTUnwrap(projected["remoteInbound"] as? [String: Any])
        }
        let actual = try report(["ssrc": 42, "reportsReceived": 3, "roundTripTimeMeasurements": 0], sender: ["ssrc": 42])
        XCTAssertEqual((actual["reportsReceived"] as? NSNumber)?.intValue, 3)
        XCTAssertEqual((actual["roundTripTimeMeasurements"] as? NSNumber)?.intValue, 0)
        for remote in [["ssrc": 43, "reportsReceived": 3], ["ssrc": 42], ["ssrc": 42, "reportsReceived": true], ["ssrc": 42, "reportsReceived": -1], ["ssrc": 42, "reportsReceived": 0.5]] as [[String: Any]] {
            let unavailable = try report(remote, sender: ["ssrc": 42])
            XCTAssertTrue(unavailable["reportsReceived"] is NSNull)
            XCTAssertTrue(unavailable["roundTripTimeMeasurements"] is NSNull)
        }
        let missing = try report(["ssrc": 42, "reportsReceived": 3], sender: nil)
        XCTAssertTrue(missing["reportsReceived"] is NSNull)
    }
}
