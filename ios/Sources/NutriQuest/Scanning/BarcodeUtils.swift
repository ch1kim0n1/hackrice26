import Foundation

/// One decoded element of a GS1 element string (e.g. from a GS1-128 or GS1 QR code).
public struct GS1Element: Identifiable {
    public let ai: String
    public let value: String
    public let label: String

    public var id: String { ai + value }
}

public enum BarcodeUtils {

    // MARK: - GTIN check digit validation (EAN-8, UPC-A/EAN-12, EAN-13, GTIN-14)

    /// Returns nil if the code is not a plain-digit GTIN of a known length,
    /// otherwise true/false for checksum validity.
    public static func validateGTINChecksum(_ code: String) -> Bool? {
        guard !code.isEmpty, code.allSatisfy(\.isNumber) else { return nil }
        guard [8, 12, 13, 14].contains(code.count) else { return nil }

        let digits = code.compactMap { $0.wholeNumberValue }
        guard digits.count == code.count else { return nil }

        let check = digits.last!
        var sum = 0
        // Weights 3,1,3,1... starting from the digit left of the check digit.
        for (i, d) in digits.dropLast().reversed().enumerated() {
            sum += d * (i % 2 == 0 ? 3 : 1)
        }
        return (10 - sum % 10) % 10 == check
    }

    // MARK: - UPC-E -> UPC-A expansion

    /// Expands an 8-digit UPC-E code to its 12-digit UPC-A equivalent so that
    /// product databases can be queried. Returns nil if not a valid UPC-E.
    public static func expandUPCE(_ code: String) -> String? {
        guard code.count == 8, code.allSatisfy(\.isNumber) else { return nil }
        let d = code.compactMap { $0.wholeNumberValue }
        guard d.count == 8, d[0] == 0 || d[0] == 1 else { return nil }

        let ns = String(d[0])
        let a = d[1], b = d[2], c = d[3], dd = d[4], e = d[5], m = d[6], check = String(d[7])

        switch m {
        case 0...2:
            return "\(ns)\(a)\(b)\(m)00" + "000\(dd)\(e)" + check
        case 3:
            return "\(ns)\(a)\(b)\(c)00" + "0000\(e)" + check
        case 4:
            return "\(ns)\(a)\(b)\(c)\(dd)0" + "0000\(e)" + check
        default:
            return "\(ns)\(a)\(b)\(c)\(dd)\(e)" + "0000\(m)" + check
        }
    }

    // MARK: - GS1 element string parsing

    private static let fixedLengthAIs: [String: Int] = [
        "00": 18, "01": 14, "02": 14,
        "11": 6, "12": 6, "13": 6, "15": 6, "16": 6, "17": 6, "18": 6, "19": 6, "20": 2,
        "390": 15, "391": 15, "392": 15, "393": 15,
        "402": 17, "410": 13, "411": 13, "412": 13, "413": 13, "414": 13, "415": 13,
        "416": 13, "417": 13, "7003": 10, "7004": 4, "7005": 6, "7006": 6,
        "7007": 12, "7008": 3, "7009": 10, "7010": 2, "7011": 10, "7020": 2,
        "703": 13, "8005": 6, "8018": 18, "8019": 8
    ]

    private static let variableLengthAIs: Set<String> = [
        "10", "21", "22", "235", "236", "237", "238", "239",
        "240", "241", "242", "243", "250", "251", "253", "254", "255",
        "400", "401", "403", "420", "421", "422", "423", "424", "425", "426", "427",
        "710", "711", "712", "713", "714", "715",
        "8008", "8017", "8020", "90", "91", "92", "93", "94", "95", "96", "97", "98", "99"
    ]

    private static let measurePrefixes: Set<String> = ["31", "32", "33", "34", "35", "36", "37"]

    private static let aiLabels: [String: String] = [
        "00": "SSCC (logistic unit)",
        "01": "GTIN",
        "02": "GTIN of contained items",
        "10": "Batch / lot number",
        "11": "Production date",
        "12": "Due date",
        "13": "Packaging date",
        "15": "Best before date",
        "16": "Sell by date",
        "17": "Expiration date",
        "20": "Internal product variant",
        "21": "Serial number",
        "22": "Consumer product variant",
        "235": "TPX (third-party extension)",
        "240": "Additional product ID",
        "241": "Customer part number",
        "250": "Secondary serial number",
        "251": "Reference to source entity",
        "253": "GDTI",
        "254": "GLN extension",
        "400": "Order number",
        "401": "GINC (consignment)",
        "402": "GSIN (shipment)",
        "403": "Routing code",
        "410": "Ship-to GLN",
        "411": "Bill-to GLN",
        "412": "Purchased-from GLN",
        "413": "Ship-for GLN",
        "414": "Physical location GLN",
        "415": "Invoicing party GLN",
        "420": "Ship-to postal code",
        "421": "Ship-to geographic code",
        "310": "Net weight (kg)",
        "315": "Net volume (L)",
        "320": "Net weight (lb)",
        "330": "Gross weight (kg)",
        "390": "Amount payable",
        "8005": "Unit price multiplier"
    ]

    /// Parses a GS1 element string such as
    /// `0103453120000011\u{1D}21ABC123` (FNC1 decoded as U+001D group separator).
    /// Returns nil when the payload does not look like GS1 data.
    public static func parseGS1(_ raw: String) -> [GS1Element]? {
        let gs = "\u{1D}"
        var input = raw
        if input.hasPrefix("]C1") { input.removeFirst(3) } // GS1 symbology identifier
        guard input.count >= 3 else { return nil }

        var elements: [GS1Element] = []
        var i = input.startIndex

        while i < input.endIndex {
            if input[i...].hasPrefix(gs) { i = input.index(after: i); continue }

            let remaining = String(input[i...])
            var ai: String?
            var valueLen = -1

            // Fixed-length AIs, longest first. Measure AIs (31x..37x) are a 2-char
            // base + 1 decimal-indicator digit: 4-char AI, 6-digit value.
            for len in [4, 3, 2] {
                guard remaining.count >= len else { continue }
                let prefix = String(remaining.prefix(len))
                if len == 2, measurePrefixes.contains(prefix) {
                    guard remaining.count >= 10,
                          let dec = remaining.dropFirst(2).first?.wholeNumberValue,
                          (0...5).contains(dec) else { continue }
                    ai = String(remaining.prefix(4))
                    valueLen = 6
                    break
                }
                guard let flen = fixedLengthAIs[prefix] else { continue }
                ai = prefix
                valueLen = flen
                break
            }

            if ai == nil {
                for len in [4, 3, 2] {
                    guard remaining.count >= len else { continue }
                    let prefix = String(remaining.prefix(len))
                    if variableLengthAIs.contains(prefix) {
                        ai = prefix
                        valueLen = -1
                        break
                    }
                }
            }

            guard let foundAI = ai else { return nil } // unknown AI -> not GS1
            guard let valueStart = input.index(i, offsetBy: foundAI.count, limitedBy: input.endIndex) else { return nil }
            var value: String

            if valueLen > 0 {
                guard let end = input.index(valueStart, offsetBy: valueLen, limitedBy: input.endIndex) else { return nil }
                value = String(input[valueStart..<end])
                i = end
            } else {
                let rest = String(input[valueStart...])
                if let gsRange = rest.range(of: gs) {
                    value = String(rest[..<gsRange.lowerBound])
                    i = input.index(valueStart, offsetBy: value.count + 1, limitedBy: input.endIndex) ?? input.endIndex
                } else {
                    value = rest
                    i = input.endIndex
                }
            }

            guard !value.isEmpty else { return nil }
            elements.append(GS1Element(ai: foundAI, value: value, label: label(for: foundAI, value: value)))
        }

        return elements.isEmpty ? nil : elements
    }

    private static func label(for ai: String, value: String) -> String {
        if measurePrefixes.contains(String(ai.prefix(2))), ai.count == 4,
           let dec = ai.last?.wholeNumberValue, let v = Double(value) {
            let name = aiLabels[String(ai.prefix(3))] ?? "Measure (\(ai))"
            return "\(name): \(v / pow(10, Double(dec)))"
        }
        if ["11", "12", "13", "15", "16", "17"].contains(ai), value.count == 6,
           let formatted = formatDate(value), let name = aiLabels[ai] {
            return "\(name): \(formatted)"
        }
        if let name = aiLabels[ai] {
            return "\(name): \(value)"
        }
        return "AI \(ai): \(value)"
    }

    private static func formatDate(_ yymmdd: String) -> String? {
        guard let yy = Int(yymmdd.prefix(2)),
              let mm = Int(yymmdd.dropFirst(2).prefix(2)),
              let dd = Int(yymmdd.suffix(2)),
              (1...12).contains(mm) else { return nil }
        let dayStr = dd == 0 ? "" : String(format: "-%02d", dd)
        return String(format: "20%02d-%02d", yy, mm) + dayStr
    }

    // MARK: - Symbology display names

    public static func symbologyName(_ rawValue: String?) -> String {
        guard let rawValue else { return "Unknown" }
        let names: [String: String] = [
            "org.gs1.EAN-13": "EAN-13",
            "org.gs1.EAN-8": "EAN-8",
            "org.gs1.UPC-E": "UPC-E",
            "org.gs1.UPC-A": "UPC-A",
            "org.gs1.DataBar": "GS1 DataBar",
            "org.gs1.DataBarLimited": "GS1 DataBar Limited",
            "org.gs1.DataBarExpanded": "GS1 DataBar Expanded",
            "org.iso.Code39": "Code 39",
            "org.iso.Code93": "Code 93",
            "org.iso.Code128": "Code 128",
            "org.iso.Codabar": "Codabar",
            "org.iso.ITF": "ITF",
            "org.iso.ITF14": "ITF-14",
            "org.iso.PDF417": "PDF417",
            "org.iso.QRCode": "QR Code",
            "org.iso.Aztec": "Aztec",
            "org.iso.DataMatrix": "Data Matrix",
            "org.iso.MicroQR": "Micro QR"
        ]
        return names[rawValue] ?? rawValue
    }

    /// Barcode most likely to be accepted by product databases:
    /// expands UPC-E to UPC-A when the expansion checksums validate.
    public static func lookupCode(for rawValue: String, symbology raw: String?) -> String {
        if raw == "org.gs1.UPC-E", let expanded = expandUPCE(rawValue),
           validateGTINChecksum(expanded) == true {
            return expanded
        }
        return rawValue
    }
}
