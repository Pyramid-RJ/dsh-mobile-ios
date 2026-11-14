import Foundation

/// Reads the validity window out of an X.509 certificate.
///
/// iOS has no `SecCertificateCopyValues` (it is macOS only), so the pinned CA's
/// expiry cannot be asked of the Security framework. docs/04 section 2 requires a
/// dedicated "CA 已过期" answer rather than a generic TLS failure, so the two
/// dates are read straight from the DER: `TBSCertificate` puts `validity` after
/// version, serial, signature and issuer, and each side is a UTCTime or a
/// GeneralizedTime.
public enum X509Validity {
    /// `notAfter`, or nil when the bytes do not parse as a certificate.
    public static func notAfter(der: Data) -> Date? {
        let bytes = [UInt8](der)
        guard let certificate = tlv(bytes, 0), certificate.tag == 0x30,
              let tbs = tlv(bytes, certificate.contentStart), tbs.tag == 0x30 else {
            return nil
        }

        var cursor = tbs.contentStart
        // version [0] is optional (v1 certificates omit it)
        if let first = tlv(bytes, cursor), first.tag == 0xA0 {
            cursor = first.end
        }
        // serialNumber, signature, issuer
        for _ in 0..<3 {
            guard let field = tlv(bytes, cursor) else { return nil }
            cursor = field.end
        }
        guard let validity = tlv(bytes, cursor), validity.tag == 0x30,
              let notBefore = tlv(bytes, validity.contentStart),
              let notAfter = tlv(bytes, notBefore.end) else {
            return nil
        }
        return time(bytes, notAfter)
    }

    /// `notBefore`, for completeness and for diagnostics.
    public static func notBefore(der: Data) -> Date? {
        let bytes = [UInt8](der)
        guard let certificate = tlv(bytes, 0), certificate.tag == 0x30,
              let tbs = tlv(bytes, certificate.contentStart), tbs.tag == 0x30 else {
            return nil
        }
        var cursor = tbs.contentStart
        if let first = tlv(bytes, cursor), first.tag == 0xA0 {
            cursor = first.end
        }
        for _ in 0..<3 {
            guard let field = tlv(bytes, cursor) else { return nil }
            cursor = field.end
        }
        guard let validity = tlv(bytes, cursor), validity.tag == 0x30,
              let notBefore = tlv(bytes, validity.contentStart) else {
            return nil
        }
        return time(bytes, notBefore)
    }

    // MARK: - DER

    private struct TLV {
        let tag: UInt8
        let contentStart: Int
        let end: Int
    }

    private static func tlv(_ bytes: [UInt8], _ offset: Int) -> TLV? {
        guard offset + 2 <= bytes.count else { return nil }
        let tag = bytes[offset]
        var cursor = offset + 1
        var length = Int(bytes[cursor])
        cursor += 1
        if length & 0x80 != 0 {
            let count = length & 0x7F
            guard count > 0, count <= 4, cursor + count <= bytes.count else { return nil }
            length = 0
            for _ in 0..<count {
                length = (length << 8) | Int(bytes[cursor])
                cursor += 1
            }
        }
        guard length >= 0, cursor + length <= bytes.count else { return nil }
        return TLV(tag: tag, contentStart: cursor, end: cursor + length)
    }

    private static func time(_ bytes: [UInt8], _ value: TLV) -> Date? {
        guard let text = String(
            bytes: bytes[value.contentStart..<value.end],
            encoding: .utf8
        ) else {
            return nil
        }
        switch value.tag {
        case 0x17: // UTCTime: YYMMDDHHMMSSZ, two-digit year
            guard text.count == 13, text.hasSuffix("Z") else { return nil }
            let year = Int(text.prefix(2)) ?? 0
            let century = year >= 50 ? 1900 : 2000
            return parse(text, prefixLength: 2, yearBase: century)
        case 0x18: // GeneralizedTime: YYYYMMDDHHMMSSZ
            guard text.count == 15, text.hasSuffix("Z") else { return nil }
            return parse(text, prefixLength: 4, yearBase: 0)
        default:
            return nil
        }
    }

    private static func parse(_ text: String, prefixLength: Int, yearBase: Int) -> Date? {
        let digits = Array(text.dropLast()) // drop the Z
        guard digits.count == 12 else { return nil }
        func number(_ start: Int, _ length: Int) -> Int? {
            Int(String(digits[start..<(start + length)]))
        }
        guard let year = number(0, prefixLength),
              let month = number(prefixLength, 2),
              let day = number(prefixLength + 2, 2),
              let hour = number(prefixLength + 4, 2),
              let minute = number(prefixLength + 6, 2),
              let second = number(prefixLength + 8, 2) else {
            return nil
        }
        var components = DateComponents()
        components.year = yearBase + year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.timeZone = TimeZone(secondsFromGMT: 0)
        return Calendar(identifier: .gregorian).date(from: components)
    }
}
