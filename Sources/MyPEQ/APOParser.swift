//  APOParser.swift
//  Universal parser, model definitions, Q-to-bandwidth math, and biquad frequency response
//  evaluator for squig.link / AutoEQ / EqualizerAPO parametric EQ (.txt) files.

import Foundation

public enum EQFilterType: String, Codable, CaseIterable, Hashable, Sendable {
    case pk = "PK"
    case lsc = "LSC"
    case ls = "LS"
    case hsc = "HSC"
    case hs = "HS"

    public var shortLabel: String {
        rawValue
    }

    public var accessibleName: String {
        switch self {
        case .pk:
            return "Peaking"
        case .lsc, .ls:
            return "Low Shelf"
        case .hsc, .hs:
            return "High Shelf"
        }
    }

    public var isShelf: Bool {
        switch self {
        case .lsc, .ls, .hsc, .hs:
            return true
        case .pk:
            return false
        }
    }
}

public struct EQBand: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var frequency: Float
    public var gain: Float
    public var q: Float
    public var type: EQFilterType
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        frequency: Float,
        gain: Float,
        q: Float,
        type: EQFilterType,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.frequency = Self.clampFrequency(frequency)
        self.gain = Self.clampGain(gain)
        self.q = Self.clampQ(q)
        self.type = type
        self.isEnabled = isEnabled
    }

    public static func clampFrequency(_ hz: Float) -> Float {
        guard hz.isFinite else { return 1000.0 }
        return min(max(hz, 10.0), 24000.0)
    }

    public static func clampGain(_ db: Float) -> Float {
        guard db.isFinite else { return 0.0 }
        return min(max(db, -30.0), 30.0)
    }

    public static func clampQ(_ q: Float) -> Float {
        guard q.isFinite else { return 0.7071 }
        return min(max(q, 0.05), 30.0)
    }
}

public struct EQProfile: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var name: String
    public var preampDB: Float
    public var bands: [EQBand]
    public let importedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        preampDB: Float = 0.0,
        bands: [EQBand] = [],
        importedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.preampDB = Self.clampPreamp(preampDB)
        self.bands = bands
        self.importedAt = importedAt
    }

    public static func clampPreamp(_ db: Float) -> Float {
        guard db.isFinite else { return 0.0 }
        return min(max(db, -20.0), 20.0)
    }

    public var enabledBandCount: Int {
        bands.filter(\.isEnabled).count
    }
}

public enum APOParserError: LocalizedError, Equatable {
    case emptyInput
    case unreadableEncoding
    case noValidEntries

    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "The selected file is empty."
        case .unreadableEncoding:
            return "Could not decode the text encoding of the selected file."
        case .noValidEntries:
            return "No valid EqualizerAPO Preamp or Filter lines were found."
        }
    }
}

public enum APOParser {
    public static let maxHardwareBands = 20

    private static let defaultShelfQ: Float = 0.70710678

    /// Converts EqualizerAPO quality factor `Q` to Apple `AVAudioUnitEQ` bandwidth in octaves:
    /// BW = ln(((2Q^2 + 1) / 2Q^2) + sqrt(((2Q^2 + 1) / 2Q^2)^2 - 1)) / ln(2)
    public static func bandwidthInOctaves(fromQ qValue: Float) -> Float {
        let q = max(Double(qValue), 0.05)
        let twoQ2 = 2.0 * q * q
        let term = (twoQ2 + 1.0) / twoQ2
        let radicand = max(term * term - 1.0, 0.0)
        let octaves = log(term + sqrt(radicand)) / log(2.0)
        return Float(min(max(octaves, 0.05), 5.0))
    }

    public static func decodeData(_ data: Data) throws -> String {
        guard !data.isEmpty else {
            throw APOParserError.emptyInput
        }

        let encodings: [String.Encoding] = [
            .utf8,
            .utf16,
            .utf16LittleEndian,
            .utf16BigEndian,
            .isoLatin1,
            .ascii
        ]

        for encoding in encodings {
            if let text = String(data: data, encoding: encoding) {
                return text
            }
        }
        throw APOParserError.unreadableEncoding
    }

    public static func parse(text rawText: String, profileName: String = "Imported Profile") throws -> EQProfile {
        let normalizedText = rawText
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedText.isEmpty else {
            throw APOParserError.emptyInput
        }

        var preampDB: Float = 0.0
        var hasPreamp = false
        var parsedBands: [EQBand] = []

        let lines = normalizedText.components(separatedBy: .newlines)
        for rawLine in lines {
            let cleanLine = stripComment(from: rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanLine.isEmpty else { continue }

            if let parsedPreamp = parsePreampLine(cleanLine) {
                preampDB = parsedPreamp
                hasPreamp = true
                continue
            }

            if let band = parseFilterLine(cleanLine) {
                parsedBands.append(band)
            }
        }

        guard hasPreamp || !parsedBands.isEmpty else {
            throw APOParserError.noValidEntries
        }

        let trimmedName = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        return EQProfile(
            name: trimmedName.isEmpty ? "Imported Profile" : trimmedName,
            preampDB: preampDB,
            bands: parsedBands
        )
    }

    public static func parse(data: Data, profileName: String) throws -> EQProfile {
        let text = try decodeData(data)
        return try parse(text: text, profileName: profileName)
    }

    public static func export(_ profile: EQProfile) -> String {
        let posix = Locale(identifier: "en_US_POSIX")
        var lines: [String] = []
        lines.append(String(format: "Preamp: %.1f dB", locale: posix, profile.preampDB))
        for (index, band) in profile.bands.enumerated() {
            let state = band.isEnabled ? "ON" : "OFF"
            let freqString: String
            if abs(band.frequency.rounded() - band.frequency) < 0.05 {
                freqString = String(format: "%.0f", locale: posix, band.frequency)
            } else {
                freqString = String(format: "%.1f", locale: posix, band.frequency)
            }
            lines.append(
                String(
                    format: "Filter %d: %@ %@ Fc %@ Hz Gain %.1f dB Q %.2f",
                    locale: posix,
                    index + 1,
                    state,
                    band.type.rawValue,
                    freqString,
                    band.gain,
                    band.q
                )
            )
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Evaluates the combined biquad frequency response magnitude in dB at `frequency` Hz
    /// using the RBJ Audio EQ Cookbook formulas matching EqualizerAPO filters.
    public static func magnitudeResponseDB(
        profile: EQProfile,
        atFrequency frequency: Double,
        sampleRate: Double = 48000.0,
        includePreamp: Bool = true
    ) -> Double {
        let fs = max(sampleRate, 8000.0)
        let f = min(max(frequency, 1.0), fs * 0.495)
        let omegaEval = 2.0 * Double.pi * f / fs
        let cosEval = cos(omegaEval)
        let sinEval = sin(omegaEval)

        var totalDB = includePreamp ? Double(profile.preampDB) : 0.0

        for band in profile.bands.prefix(maxHardwareBands) where band.isEnabled {
            let fc = min(max(Double(band.frequency), 1.0), fs * 0.495)
            let gainDB = Double(band.gain)
            if abs(gainDB) < 1e-6 {
                continue
            }

            let q = max(Double(band.q), 0.05)
            let omega0 = 2.0 * Double.pi * fc / fs
            let cosW0 = cos(omega0)
            let sinW0 = sin(omega0)
            let alpha = sinW0 / (2.0 * q)
            let aAmp = pow(10.0, gainDB / 40.0)

            let b0: Double
            let b1: Double
            let b2: Double
            let a0: Double
            let a1: Double
            let a2: Double

            switch band.type {
            case .pk:
                b0 = 1.0 + alpha * aAmp
                b1 = -2.0 * cosW0
                b2 = 1.0 - alpha * aAmp
                a0 = 1.0 + alpha / aAmp
                a1 = -2.0 * cosW0
                a2 = 1.0 - alpha / aAmp

            case .lsc, .ls:
                let sqrtA2Alpha = 2.0 * sqrt(aAmp) * alpha
                let aPlus = aAmp + 1.0
                let aMinus = aAmp - 1.0
                b0 = aAmp * (aPlus - aMinus * cosW0 + sqrtA2Alpha)
                b1 = 2.0 * aAmp * (aMinus - aPlus * cosW0)
                b2 = aAmp * (aPlus - aMinus * cosW0 - sqrtA2Alpha)
                a0 = aPlus + aMinus * cosW0 + sqrtA2Alpha
                a1 = -2.0 * (aMinus + aPlus * cosW0)
                a2 = aPlus + aMinus * cosW0 - sqrtA2Alpha

            case .hsc, .hs:
                let sqrtA2Alpha = 2.0 * sqrt(aAmp) * alpha
                let aPlus = aAmp + 1.0
                let aMinus = aAmp - 1.0
                b0 = aAmp * (aPlus + aMinus * cosW0 + sqrtA2Alpha)
                b1 = -2.0 * aAmp * (aMinus + aPlus * cosW0)
                b2 = aAmp * (aPlus + aMinus * cosW0 - sqrtA2Alpha)
                a0 = aPlus - aMinus * cosW0 + sqrtA2Alpha
                a1 = 2.0 * (aMinus - aPlus * cosW0)
                a2 = aPlus - aMinus * cosW0 - sqrtA2Alpha
            }

            let reNum = (b0 + b2) * cosEval + b1
            let imNum = (b0 - b2) * sinEval
            let reDen = (a0 + a2) * cosEval + a1
            let imDen = (a0 - a2) * sinEval

            let numMag2 = reNum * reNum + imNum * imNum
            let denMag2 = max(reDen * reDen + imDen * imDen, 1e-24)
            totalDB += 10.0 * log10(max(numMag2 / denMag2, 1e-12))
        }

        return totalDB
    }

    // MARK: - Line Parsing Helpers

    private static func stripComment(from line: String) -> String {
        guard let hashIndex = line.firstIndex(of: "#") else {
            return line
        }
        return String(line[..<hashIndex])
    }

    private static func parseLocalizedFloat(_ token: String) -> Float? {
        let cleaned = token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        return Float(cleaned)
    }

    private static func parsePreampLine(_ line: String) -> Float? {
        let pattern = #"^\s*Preamp\s*:\s*([+-]?\d+(?:[.,]\d+)?)\s*(?:dB)?\s*$"#
        guard let captures = firstRegexCaptures(pattern: pattern, in: line),
              let value = parseLocalizedFloat(captures[0]) else {
            return nil
        }
        return EQProfile.clampPreamp(value)
    }

    private static func parseFilterLine(_ line: String) -> EQBand? {
        let headerPattern = #"^\s*Filter(?:\s+\d+)?\s*:\s*(ON|OFF)\s+(PK|LSC|LS|HSC|HS)\b(.*)$"#
        guard let headerCaptures = firstRegexCaptures(pattern: headerPattern, in: line) else {
            return nil
        }

        let isEnabled = headerCaptures[0].uppercased() == "ON"
        guard let filterType = EQFilterType(rawValue: headerCaptures[1].uppercased()) else {
            return nil
        }

        let body = headerCaptures[2]

        guard let fcMatch = firstRegexCaptures(
            pattern: #"\bFc\s+([+-]?\d+(?:[.,]\d+)?)\s*(k?Hz)?\b"#,
            in: body
        ),
        let rawFreq = parseLocalizedFloat(fcMatch[0]) else {
            return nil
        }

        let freqUnit = fcMatch[1].lowercased()
        let frequencyHz = freqUnit == "khz" ? rawFreq * 1000.0 : rawFreq
        guard frequencyHz > 0.0 else {
            return nil
        }

        guard let gainMatch = firstRegexCaptures(
            pattern: #"\bGain\s+([+-]?\d+(?:[.,]\d+)?)(?:\s*dB)?\b"#,
            in: body
        ),
        let gainDB = parseLocalizedFloat(gainMatch[0]) else {
            return nil
        }

        let parsedQ: Float
        if let qMatch = firstRegexCaptures(
            pattern: #"\bQ\s+([+-]?\d+(?:[.,]\d+)?)\b"#,
            in: body
        ),
        let qValue = parseLocalizedFloat(qMatch[0]), qValue > 0.0 {
            parsedQ = qValue
        } else if filterType.isShelf {
            parsedQ = defaultShelfQ
        } else {
            return nil
        }

        return EQBand(
            frequency: frequencyHz,
            gain: gainDB,
            q: parsedQ,
            type: filterType,
            isEnabled: isEnabled
        )
    }

    private static func firstRegexCaptures(pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else {
            return nil
        }
        var results: [String] = []
        for idx in 1..<match.numberOfRanges {
            let groupRange = match.range(at: idx)
            if groupRange.location != NSNotFound, let swiftRange = Range(groupRange, in: text) {
                results.append(String(text[swiftRange]))
            } else {
                results.append("")
            }
        }
        return results
    }
}
