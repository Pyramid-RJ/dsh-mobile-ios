import Foundation

/// Display scale rules shared by the bridge and the web view (docs/03 section 6.1).
public enum DisplayScalePolicy {
    public static let minimum = 80
    public static let maximum = 125

    /// Parses the page's percent value; anything outside 80...125 is bad_message.
    public static func percent(from input: [String: Any]) -> Int? {
        let raw = input["percent"]
        let value: Int?
        if let number = raw as? NSNumber {
            value = number.intValue
            // Reject 87.5 and similar: the contract says integer.
            if number.doubleValue != Double(number.intValue) { return nil }
        } else if let text = raw as? String, let parsed = Int(text) {
            value = parsed
        } else {
            value = nil
        }
        guard let value, (minimum...maximum).contains(value) else { return nil }
        return value
    }

    /// viewportWidth = round(nativeWidth / density / (percent / 100))
    public static func viewportWidth(nativeWidth: Double, density: Double, percent: Int) -> Int {
        guard density > 0, percent > 0 else { return 0 }
        let width = nativeWidth / density / (Double(percent) / 100.0)
        return Int(width.rounded())
    }

    /// Reply shape the page validates: percent plus the accepted range.
    public static func reply(percent: Int) -> [String: Any] {
        ["percent": percent, "minPercent": minimum, "maxPercent": maximum]
    }
}
