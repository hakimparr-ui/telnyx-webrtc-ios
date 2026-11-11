import Foundation
import XCTest
@testable import TelnyxRTC

final class CallingReportCandidateSelectionTests: XCTestCase {
    private func select(_ statistics: [String: [String: Any]], transportId: String? = "audio") -> String? {
        TelnyxCallReportCollector.selectedAudioCandidatePairId(transportId: transportId, statistics: statistics)
    }

    func testAudioTransportSelectsActualCountersInsteadOfSucceededDecoys() throws {
        let statistics: [String: [String: Any]] = [
            "audio": ["type": "transport", "selectedCandidatePairId": "active"],
            "other": ["type": "transport", "selectedCandidatePairId": "decoy"],
            "active": ["type": "candidate-pair", "state": "succeeded", "packetsSent": 6121, "bytesSent": 979360],
            "decoy": ["type": "candidate-pair", "state": "succeeded", "nominated": true, "selected": true, "packetsSent": 0],
        ]
        let selected = try XCTUnwrap(select(statistics))
        XCTAssertEqual(selected, "active")
        XCTAssertEqual(statistics[selected]?["packetsSent"] as? Int, 6121)
        XCTAssertEqual(statistics[selected]?["bytesSent"] as? Int, 979360)
    }

    func testDanglingOrInvalidAuthoritativeReferenceNeverUsesLegacyPair() {
        for reference in ["missing" as Any, 4, NSNull()] {
            XCTAssertNil(select([
                "audio": ["type": "transport", "selectedCandidatePairId": reference],
                "legacy": ["type": "candidate-pair", "transportId": "audio", "selected": true, "state": "succeeded"],
            ]))
        }
        XCTAssertNil(select([
            "audio": ["type": "transport", "selectedCandidatePairId": "wrong"],
            "wrong": ["type": "remote-candidate", "selected": true, "state": "succeeded"],
        ]))
    }

    func testMissingOrWrongTransportDoesNotUseAnotherTransport() {
        for transport in [[:], ["type": "candidate-pair"]] {
            XCTAssertNil(select([
                "audio": transport,
                "other": ["type": "transport", "selectedCandidatePairId": "active"],
                "active": ["type": "candidate-pair", "selected": true, "state": "succeeded"],
            ]))
        }
    }

    func testNewSelectedPairDoesNotReuseOldCounters() {
        var statistics: [String: [String: Any]] = [
            "audio": ["type": "transport", "selectedCandidatePairId": "first"],
            "first": ["type": "candidate-pair", "state": "succeeded", "nominated": true, "packetsSent": 100],
            "second": ["type": "candidate-pair", "state": "succeeded", "packetsSent": 0],
        ]
        XCTAssertEqual(select(statistics), "first")
        statistics["audio"]?["selectedCandidatePairId"] = "second"
        XCTAssertEqual(select(statistics), "second")
        statistics.removeValue(forKey: "second")
        XCTAssertNil(select(statistics))
    }

    func testSelectedPairStillReportsCountersWhenItsStateFails() {
        XCTAssertEqual(select([
            "audio": ["type": "transport", "selectedCandidatePairId": "active"],
            "active": ["type": "candidate-pair", "state": "failed"],
            "decoy": ["type": "candidate-pair", "state": "succeeded", "nominated": true],
        ]), "active")
    }

    func testLegacyFallbackRequiresExplicitUniqueSelectedPair() {
        let selected: [String: Any] = ["type": "candidate-pair", "selected": true, "state": "succeeded"]
        XCTAssertEqual(select(["legacy": selected], transportId: nil), "legacy")
        XCTAssertNil(select(["first": selected, "second": selected], transportId: nil))
        XCTAssertNil(select(["nominated": ["type": "candidate-pair", "nominated": true, "state": "succeeded"]], transportId: nil))
        XCTAssertNil(select(["succeeded": ["type": "candidate-pair", "state": "succeeded"]], transportId: nil))
        XCTAssertNil(select(["failed": ["type": "candidate-pair", "selected": true, "state": "failed"]], transportId: nil))
    }

    func testLegacyFallbackHonoursKnownAudioTransportOwnership() {
        let statistics: [String: [String: Any]] = [
            "audio": ["type": "transport"],
            "active": ["type": "candidate-pair", "transportId": "audio", "selected": true, "state": "succeeded"],
            "other": ["type": "candidate-pair", "transportId": "video", "selected": true, "state": "succeeded"],
        ]
        XCTAssertEqual(select(statistics), "active")
        var missingOwnership = statistics
        missingOwnership["active"]?.removeValue(forKey: "transportId")
        XCTAssertNil(select(missingOwnership))
    }

    func testUnidentifiedAudioTransportCannotOverrideModernTransportReferences() {
        XCTAssertNil(select([
            "other": ["type": "transport", "selectedCandidatePairId": "active"],
            "active": ["type": "candidate-pair", "selected": true, "state": "succeeded"],
        ], transportId: nil))
    }
}
