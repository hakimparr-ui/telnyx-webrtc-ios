import Foundation
import XCTest
@testable import TelnyxRTC

final class CallingMediaDiagnosticsTests: XCTestCase {
    func testCodecIsResolvedFromTheMatchingStreamReference() throws {
        let stats: [String: Any] = [
            "codecId": "G722-codec", "ssrc": 123, "packetsReceived": 90,
        ]
        let result = WebRTCStatsReporter.resolvingAudioCodec(stats, from: [
            "other-codec": ["type": "codec", "mimeType": "audio/opus", "clockRate": 48_000],
            "G722-codec": [
                "type": "codec", "mimeType": "audio/G722", "clockRate": 8_000,
                "channels": 1, "sdpFmtpLine": "private-parameters",
                "transportId": "private-transport",
            ],
        ])
        let codec = try XCTUnwrap(result["codec"] as? [String: Any])
        XCTAssertEqual(codec["mimeType"] as? String, "audio/G722")
        XCTAssertEqual(codec["clockRate"] as? Int, 8_000)
        XCTAssertEqual(codec["channels"] as? Int, 1)
        XCTAssertEqual(Set(codec.keys), ["mimeType", "clockRate", "channels"])
        XCTAssertEqual(result["ssrc"] as? Int, 123)
        XCTAssertEqual(result["packetsReceived"] as? Int, 90)
    }

    func testMissingCodecDoesNotReuseStaleMetadataOrBecomeZero() throws {
        let result = WebRTCStatsReporter.resolvingAudioCodec([
            "codecId": "gone", "codec": ["mimeType": "audio/opus"],
        ], from: [:])
        let codec = try XCTUnwrap(result["codec"] as? [String: Any])
        for key in ["mimeType", "clockRate", "channels"] {
            XCTAssertTrue(codec[key] is NSNull, key)
        }
        XCTAssertTrue(JSONSerialization.isValidJSONObject(result))
    }

    func testInvalidCodecMeasurementsRemainUnavailable() throws {
        let invalidValues: [Any] = [Double.infinity, Double.nan, true, -1, 0, 48_000.5, 1_000_000]
        for invalid in invalidValues {
            let result = WebRTCStatsReporter.resolvingAudioCodec(["codecId": "codec"], from: [
                "codec": ["type": "codec", "mimeType": "audio/opus", "clockRate": invalid],
            ])
            let codec = try XCTUnwrap(result["codec"] as? [String: Any])
            XCTAssertTrue(codec["clockRate"] is NSNull)
            XCTAssertTrue(codec["channels"] is NSNull)
            XCTAssertTrue(JSONSerialization.isValidJSONObject(result))
        }
    }

    func testOnlyBoundedAudioCodecMetadataIsAccepted() throws {
        let invalidSources: [[String: Any]] = [
            ["type": "candidate-pair", "mimeType": "audio/opus", "clockRate": 48_000],
            ["type": "codec", "mimeType": "video/VP8", "clockRate": 90_000],
            ["type": "codec", "mimeType": "audio/opus\r\na=private", "clockRate": 48_000],
            ["type": "codec", "mimeType": "audio/" + String(repeating: "x", count: 65)],
        ]
        for source in invalidSources {
            let result = WebRTCStatsReporter.resolvingAudioCodec(["codecId": "codec"], from: [
                "codec": source,
            ])
            let codec = try XCTUnwrap(result["codec"] as? [String: Any])
            XCTAssertTrue(codec["mimeType"] is NSNull)
            XCTAssertTrue(codec["clockRate"] is NSNull)
            XCTAssertTrue(codec["channels"] is NSNull)
        }
    }
}
