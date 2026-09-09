//
//  SdpUtils.swift
//  TelnyxRTC
//
//  Created by Telnyx on 2025.
//  Copyright © 2025 Telnyx LLC. All rights reserved.
//

import Foundation

/// Utility class for Session Description Protocol (SDP) manipulation.
class SdpUtils {

    /// WebRTC 124 selects its audio sender from the remote offer's payload
    /// order. Transceiver preferences affect the answer and receiving direction.
    /// Reorder only offered audio payloads in the local input to WebRTC, keeping
    /// every fallback and attribute. Unknown or ambiguous sections stay intact.
    static func preferringAudioCodecs(
        in sdp: String,
        preferredCodecs: [TxCodecCapability]
    ) -> String {
        guard !preferredCodecs.isEmpty, preferredCodecs.count <= 32,
              preferredCodecs.allSatisfy({ $0.mimeType.utf8.count <= 70 }),
              sdp.utf8.count <= 65_536 else { return sdp }
        // Splitting on LF retains each line's optional CR and the final newline.
        var lines = sdp.components(separatedBy: "\n")
        guard lines.count <= 2_048 else { return sdp }
        let mediaStarts = lines.indices.filter { lines[$0].hasPrefix("m=") }
        for (section, start) in mediaStarts.enumerated() {
            let end = section + 1 < mediaStarts.count ? mediaStarts[section + 1] : lines.count
            if let reordered = preferringAudioPayloads(
                in: lines[start], attributes: lines[(start + 1)..<end],
                preferredCodecs: preferredCodecs
            ) {
                lines[start] = reordered
            }
        }
        return lines.joined(separator: "\n")
    }

    private struct OfferedAudioCodec: Equatable {
        let name: String
        let clockRate: Int
        let channels: Int

        func matches(_ preferred: TxCodecCapability) -> Bool {
            preferred.mimeType.lowercased() == "audio/" + name &&
                preferred.clockRate == clockRate &&
                (preferred.channels == nil || preferred.channels == channels)
        }
    }

    private static func preferringAudioPayloads(
        in rawLine: String,
        attributes: ArraySlice<String>,
        preferredCodecs: [TxCodecCapability]
    ) -> String? {
        let suffix = rawLine.hasSuffix("\r") ? "\r" : ""
        let line = suffix.isEmpty ? rawLine : String(rawLine.dropLast())
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count >= 4, fields.count <= 131, fields[0] == "m=audio",
              fields[2].split(separator: "/").contains("RTP") else { return nil }
        let port = fields[1].split(separator: "/", omittingEmptySubsequences: false)
        guard port.count <= 2,
              sdpInteger(port[0], in: 1...65_535) != nil else { return nil }
        if port.count == 2, sdpInteger(port[1], in: 1...65_535) == nil { return nil }

        let payloadFields = Array(fields.dropFirst(3))
        let payloads = payloadFields.compactMap { sdpInteger($0, in: 0...127) }
        guard payloads.count == payloadFields.count,
              Set(payloads).count == payloads.count else { return nil }
        // RFC 3551 mappings used by the supported telephony codecs. Explicit
        // rtpmap values take precedence, including clock rate and channel count.
        let staticCodecs: [Int: OfferedAudioCodec] = [
            0: OfferedAudioCodec(name: "pcmu", clockRate: 8_000, channels: 1),
            8: OfferedAudioCodec(name: "pcma", clockRate: 8_000, channels: 1),
            9: OfferedAudioCodec(name: "g722", clockRate: 8_000, channels: 1),
        ]
        var mappings = staticCodecs.filter { payloads.contains($0.key) }
        var explicitMappings: [Int: OfferedAudioCodec] = [:]
        for rawAttribute in attributes {
            let attribute = rawAttribute.hasSuffix("\r")
                ? String(rawAttribute.dropLast()) : rawAttribute
            guard attribute.hasPrefix("a=rtpmap:") else { continue }
            let parts = attribute.dropFirst("a=rtpmap:".count)
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2,
                  let payload = sdpInteger(parts[0], in: 0...127) else { return nil }
            guard payloads.contains(payload) else { continue }
            let format = parts[1].split(separator: "/", omittingEmptySubsequences: false)
            guard (2...3).contains(format.count), !format[0].isEmpty,
                  format[0].utf8.count <= 64,
                  format[0].utf8.allSatisfy({ $0 > 32 && $0 < 127 }),
                  let clockRate = sdpInteger(format[1], in: 1...384_000),
                  let channels = format.count == 3
                    ? sdpInteger(format[2], in: 1...24) : 1 else { return nil }
            let codec = OfferedAudioCodec(
                name: format[0].lowercased(), clockRate: clockRate, channels: channels
            )
            if let prior = explicitMappings[payload], prior != codec { return nil }
            if let fixed = staticCodecs[payload], fixed.name != codec.name { return nil }
            explicitMappings[payload] = codec
            mappings[payload] = codec
        }

        var orderedIndices: [Int] = []
        for preferred in preferredCodecs {
            for index in payloads.indices where !orderedIndices.contains(index) {
                if mappings[payloads[index]]?.matches(preferred) == true {
                    orderedIndices.append(index)
                }
            }
        }
        guard !orderedIndices.isEmpty else { return nil }
        orderedIndices.append(contentsOf: payloads.indices.filter { !orderedIndices.contains($0) })
        guard orderedIndices != Array(payloads.indices) else { return nil }

        // Keep the m line's prefix, spacing, payload spelling and trailing CR.
        // Only move the payload tokens into their preferred positions.
        var result = ""
        var cursor = line.startIndex
        for (position, field) in payloadFields.enumerated() {
            result += line[cursor..<field.startIndex]
            result += payloadFields[orderedIndices[position]]
            cursor = field.endIndex
        }
        result += line[cursor...]
        return result + suffix
    }

    private static func sdpInteger(_ text: Substring, in range: ClosedRange<Int>) -> Int? {
        guard !text.isEmpty, text.utf8.count <= 6,
              text.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let value = Int(text), range.contains(value) else { return nil }
        return value
    }

    /// Adds trickle ICE capability to an SDP if not already present.
    /// This adds "a=ice-options:trickle" at the session level after the origin (o=) line.
    ///
    /// - Parameters:
    ///   - sdp: The original SDP string
    ///   - useTrickleIce: Whether trickle ICE is enabled
    /// - Returns: The modified SDP with ice-options:trickle added, or original if no modification needed
    static func addTrickleIceCapability(_ sdp: String, useTrickleIce: Bool) -> String {
        guard useTrickleIce else {
            return sdp
        }

        var lines = sdp.components(separatedBy: "\r\n")

        if let result = handleTrickleIceModification(&lines) {
            Logger.log.i(message: "SdpUtils :: Modified SDP with trickle ICE capability")
            return result
        } else {
            Logger.log.i(message: "SdpUtils :: SDP already contains trickle ICE or no modification needed")
            return sdp
        }
    }

    /// Handles trickle ICE modification by checking existing ice-options and adding if needed
    /// - Parameter lines: Array of SDP lines (passed as inout for modification)
    /// - Returns: Modified SDP string if changes were made, nil otherwise
    private static func handleTrickleIceModification(_ lines: inout [String]) -> String? {
        // Check if there's an existing ice-options line that needs modification
        if let existingIceOptionsIndex = findExistingIceOptionsIndex(lines) {
            return handleExistingIceOptions(&lines, at: existingIceOptionsIndex)
        }

        // If no existing ice-options line was found, try to add a new one
        return addNewIceOptions(&lines)
    }

    /// Finds the index of an existing ice-options line
    /// - Parameter lines: Array of SDP lines
    /// - Returns: Index of ice-options line, or nil if not found
    private static func findExistingIceOptionsIndex(_ lines: [String]) -> Int? {
        for (index, line) in lines.enumerated() {
            if line.hasPrefix("a=ice-options:") {
                return index
            }
        }
        return nil
    }

    /// Handles an existing ice-options line
    /// - Parameters:
    ///   - lines: Array of SDP lines (passed as inout for modification)
    ///   - index: Index of the existing ice-options line
    /// - Returns: Modified SDP string if changes were made, nil if already correct
    private static func handleExistingIceOptions(_ lines: inout [String], at index: Int) -> String? {
        let currentOptions = lines[index]

        if currentOptions == "a=ice-options:trickle" {
            // Already has exactly what we want
            return nil
        } else {
            // Replace any ice-options line with just trickle
            // This handles cases like "a=ice-options:trickle renomination"
            lines[index] = "a=ice-options:trickle"
            Logger.log.i(message: "SdpUtils :: Replaced ice-options line from '\(currentOptions)' to 'a=ice-options:trickle'")
            return lines.joined(separator: "\r\n")
        }
    }

    /// Adds a new ice-options line to the SDP
    /// - Parameter lines: Array of SDP lines (passed as inout for modification)
    /// - Returns: Modified SDP string if line was added, nil if origin line not found
    private static func addNewIceOptions(_ lines: inout [String]) -> String? {
        guard let insertIndex = findOriginLineInsertIndex(lines) else {
            Logger.log.w(message: "SdpUtils :: Could not find origin line in SDP, returning original")
            return nil
        }

        // Insert ice-options:trickle at session level (after origin line)
        lines.insert("a=ice-options:trickle", at: insertIndex)
        Logger.log.i(message: "SdpUtils :: Added a=ice-options:trickle to SDP at index \(insertIndex)")
        return lines.joined(separator: "\r\n")
    }

    /// Finds the index where the ice-options line should be inserted (after origin line)
    /// - Parameter lines: Array of SDP lines
    /// - Returns: Index after origin line, or nil if origin line not found
    private static func findOriginLineInsertIndex(_ lines: [String]) -> Int? {
        for (index, line) in lines.enumerated() {
            if line.hasPrefix("o=") {
                return index + 1
            }
        }
        return nil
    }

    /// Checks if an SDP contains trickle ICE capability.
    ///
    /// - Parameter sdp: The SDP string to check
    /// - Returns: true if the SDP advertises trickle ICE support
    static func hasTrickleIceCapability(_ sdp: String) -> Bool {
        return sdp.contains("a=ice-options:trickle")
    }

    /// Removes ICE candidates from SDP for trickle ICE
    ///
    /// - Parameter sdp: The SDP string to process
    /// - Returns: The SDP with ICE candidates removed
    static func removeIceCandidatesFromSdp(_ sdp: String) -> String {
        let lines = sdp.components(separatedBy: "\r\n")
        let modifiedLines = lines.filter { line in
            // Remove candidate lines (a=candidate:)
            !line.hasPrefix("a=candidate:")
        }

        let modifiedSdp = modifiedLines.joined(separator: "\r\n")
        Logger.log.i(message: "SdpUtils :: Removed ICE candidates from SDP for trickle ICE")
        return modifiedSdp
    }

    /// Cleans an ICE candidate string to remove WebRTC-specific extensions.
    /// Extracts only the RFC 5245/8838 standard fields from a WebRTC candidate string.
    ///
    /// Standard format: candidate:<foundation> <component> <transport> <priority> <IP address> <port> typ <candidate-type> [raddr <IP>] [rport <port>]
    ///
    /// - Parameter candidateString: The raw candidate string from WebRTC (e.g., from RTCIceCandidate.sdp)
    /// - Returns: The cleaned candidate string with only RFC-compliant fields
    static func cleanCandidateString(_ candidateString: String) -> String {
        Logger.log.i(message: "[CANDIDATE-CLEAN] SdpUtils:: Original candidate: \(candidateString)")

        // Split the candidate string into parts
        let parts = candidateString.trimmingCharacters(in: .whitespaces).components(separatedBy: " ")

        // Validate candidate format
        guard !parts.isEmpty, parts[0].hasPrefix("candidate:") else {
            Logger.log.w(message: "[CANDIDATE-CLEAN] SdpUtils:: Invalid candidate format: \(candidateString)")
            return candidateString
        }

        var cleanedParts: [String] = []
        var i = 0

        // Process standard fields: foundation(0), component(1), transport(2), priority(3), IP(4), port(5), typ(6), candidate-type(7)
        // Also keep raddr and rport pairs for relay candidates
        while i < parts.count {
            let part = parts[i]

            // Keep standard candidate fields (indices 0-7)
            if i < 8 {
                cleanedParts.append(part)
                i += 1
                continue
            }

            // Keep raddr and its value
            if part == "raddr" && i + 1 < parts.count {
                cleanedParts.append(part)
                cleanedParts.append(parts[i + 1])
                i += 2
                continue
            }

            // Keep rport and its value
            if part == "rport" && i + 1 < parts.count {
                cleanedParts.append(part)
                cleanedParts.append(parts[i + 1])
                i += 2
                continue
            }

            // Skip WebRTC-specific extensions (network-id, generation, ufrag, network-cost)
            if part == "network-id" || part == "generation" || part == "ufrag" || part == "network-cost" {
                // Skip the extension and its value
                i += 2
                continue
            }

            // Skip any other unknown fields
            Logger.log.i(message: "[CANDIDATE-CLEAN] SdpUtils:: Skipping unknown field: \(part)")
            i += 1
        }

        let cleanedCandidate = cleanedParts.joined(separator: " ")
        Logger.log.i(message: "[CANDIDATE-CLEAN] SdpUtils:: Cleaned candidate: \(cleanedCandidate)")

        return cleanedCandidate
    }
}
