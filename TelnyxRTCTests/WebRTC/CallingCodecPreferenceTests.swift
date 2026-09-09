import Foundation
import XCTest
@testable import TelnyxRTC

final class CallingCodecPreferenceTests: XCTestCase {
    private let preferences = [
        TxCodecCapability(mimeType: "audio/opus", clockRate: 48_000, channels: 2),
        TxCodecCapability(mimeType: "audio/PCMU", clockRate: 8_000, channels: 1),
    ]

    private func prefer(_ sdp: String) -> String {
        SdpUtils.preferringAudioCodecs(in: sdp, preferredCodecs: preferences)
    }

    func testOfferedOpusAndPCMUPrecedeG722WithoutRemovingFallbacksOrAttributes() {
        let offer = [
            "v=0", "o=- 1 1 IN IP4 127.0.0.1", "s=synthetic", "t=0 0",
            "m=audio 9 UDP/TLS/RTP/SAVPF 9 0 111 101",
            "a=mid:audio", "a=rtpmap:9 G722/8000", "a=rtpmap:111 opus/48000/2",
            "a=fmtp:111 minptime=10;useinbandfec=1", "a=rtpmap:101 telephone-event/8000",
            "a=rtpmap:112 opus/48000/2", "a=ice-ufrag:synthetic",
            "a=sendrecv", "a=ptime:20", "",
        ].joined(separator: "\r\n")
        XCTAssertEqual(prefer(offer), offer.replacingOccurrences(
            of: "m=audio 9 UDP/TLS/RTP/SAVPF 9 0 111 101",
            with: "m=audio 9 UDP/TLS/RTP/SAVPF 111 0 9 101"
        ))
    }

    func testStaticPCMUIsRecognizedWithoutAnRtpmapLine() {
        let offer = "v=0\r\nm=audio 9 RTP/AVP 9 0\r\na=rtpmap:9 G722/8000\r\n"
        XCTAssertEqual(prefer(offer), offer.replacingOccurrences(
            of: "RTP/AVP 9 0", with: "RTP/AVP 0 9"
        ))
    }

    func testG722OnlyOfferAndMissingPreferencesStayByteIdentical() {
        let fallback = "v=0\r\nm=audio 9 RTP/AVP 9 101\r\na=rtpmap:101 telephone-event/8000\r\n"
        XCTAssertEqual(prefer(fallback), fallback)
        let offeredOpus = "m=audio 9 RTP/AVP 9 111\na=rtpmap:111 opus/48000/2\n"
        XCTAssertEqual(SdpUtils.preferringAudioCodecs(in: offeredOpus, preferredCodecs: []), offeredOpus)
        let unknown = [TxCodecCapability(mimeType: "audio/unknown", clockRate: 8_000)]
        XCTAssertEqual(SdpUtils.preferringAudioCodecs(in: offeredOpus, preferredCodecs: unknown), offeredOpus)
    }

    func testEachMediaSectionUsesOnlyItsOwnPayloadMappings() {
        let offer = [
            "v=0", "a=group:BUNDLE video first second third data",
            "m=video 9 UDP/TLS/RTP/SAVPF 9 97", "a=mid:video", "a=rtpmap:97 VP8/90000",
            "m=audio 9 UDP/TLS/RTP/SAVPF 9 97", "a=mid:first", "a=rtpmap:97 OPUS/48000/2",
            "m=audio 9 UDP/TLS/RTP/SAVPF 9 97", "a=mid:second", "a=rtpmap:97 ISAC/16000",
            "m=audio 9 RTP/AVP 9 0", "a=mid:third",
            "m=application 9 UDP/DTLS/SCTP webrtc-datachannel", "a=mid:data", "",
        ].joined(separator: "\r\n")
        let expected = offer.replacingOccurrences(
            of: "m=audio 9 UDP/TLS/RTP/SAVPF 9 97\r\na=mid:first",
            with: "m=audio 9 UDP/TLS/RTP/SAVPF 97 9\r\na=mid:first"
        ).replacingOccurrences(of: "m=audio 9 RTP/AVP 9 0", with: "m=audio 9 RTP/AVP 0 9")
        XCTAssertEqual(prefer(offer), expected)
    }

    func testMixedLineEndingsAndPayloadSpacingArePreserved() {
        let offer = "v=0\r\ns=synthetic\nm=audio\t9  RTP/AVP\t9  111\t0 \r\na=rtpmap:111 opus/48000/2\na=sendrecv"
        let expected = offer.replacingOccurrences(
            of: "RTP/AVP\t9  111\t0 ", with: "RTP/AVP\t111  0\t9 "
        )
        XCTAssertEqual(prefer(offer), expected)
        XCTAssertEqual(prefer(expected), expected)
    }

    func testClockRateAndChannelsMustMatchAndMonoDefaultsToOne() {
        for mapping in ["opus/16000/2", "opus/48000", "opus/48000/1"] {
            let offer = "m=audio 9 RTP/AVP 9 111\na=rtpmap:111 \(mapping)\n"
            XCTAssertEqual(prefer(offer), offer)
        }
        let mono = "m=audio 9 RTP/AVP 9 96\na=rtpmap:96 pcmu/8000\n"
        XCTAssertEqual(prefer(mono), mono.replacingOccurrences(of: "RTP/AVP 9 96", with: "RTP/AVP 96 9"))
        let explicitStaticChannels = "m=audio 9 RTP/AVP 9 0\na=rtpmap:0 PCMU/8000/2\n"
        XCTAssertEqual(prefer(explicitStaticChannels), explicitStaticChannels)
    }

    func testDuplicatePreferencesAndSameCodecPayloadsKeepStableOrder() {
        let offer = "m=audio 9 RTP/AVP 9 112 111 0 101\na=rtpmap:112 opus/48000/2\na=rtpmap:111 opus/48000/2\n"
        let result = SdpUtils.preferringAudioCodecs(
            in: offer, preferredCodecs: preferences + preferences
        )
        XCTAssertEqual(result, offer.replacingOccurrences(
            of: "RTP/AVP 9 112 111 0 101", with: "RTP/AVP 112 111 0 9 101"
        ))
    }

    func testRejectedAndNonRtpAudioSectionsAreUntouched() {
        for media in ["m=audio 0 RTP/AVP 9 111", "m=audio 9 UDP 9 111", "m=video 9 RTP/AVP 9 111"] {
            let offer = media + "\r\na=rtpmap:111 opus/48000/2\r\n"
            XCTAssertEqual(prefer(offer), offer)
        }
    }

    func testAmbiguousAndMalformedMappingsAreLeftForWebRTCToValidate() {
        let prefix = "m=audio 9 RTP/AVP 9 111\na=rtpmap:111 "
        let offers = [
            prefix + "opus/48000/2\na=rtpmap:111 PCMU/8000\n",
            prefix + "opus/48000x/2\n",
            prefix + "opus/48000/0\n",
            "m=audio 9 RTP/AVP 9 111 111\na=rtpmap:111 opus/48000/2\n",
            "m=audio 9 RTP/AVP 9 0\na=rtpmap:0 opus/48000/2\n",
            "m=audio 9 RTP/AVP 9 invalid\na=rtpmap:111 opus/48000/2\n",
        ]
        for offer in offers { XCTAssertEqual(prefer(offer), offer) }
    }

    func testOversizedInputUsesTheOriginalOffer() {
        let offer = "m=audio 9 RTP/AVP 9 0\r\na=x:" + String(repeating: "x", count: 65_536)
        XCTAssertEqual(prefer(offer), offer)
        let tooManyLines = "m=audio 9 RTP/AVP 9 0\n" + String(repeating: "a=x\n", count: 2_048)
        XCTAssertEqual(prefer(tooManyLines), tooManyLines)
        let valid = "m=audio 9 RTP/AVP 9 0\r\n"
        XCTAssertEqual(SdpUtils.preferringAudioCodecs(
            in: valid, preferredCodecs: Array(repeating: preferences[1], count: 33)
        ), valid)
    }
}
