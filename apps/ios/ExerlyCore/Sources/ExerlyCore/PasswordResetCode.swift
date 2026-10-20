import Foundation

/// A password reset code as the API mails it: eight characters with no 0, O,
/// 1 or I, shown as ABCD-EFGH.
public enum PasswordResetCode {
    public static let length = 8
    private static let alphabet = Set("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")

    /// The code characters typed so far, upper-cased, without spaces, dashes or
    /// anything a code can't hold, and at most eight.
    private static func characters(_ typed: String) -> [Character] {
        Array(typed.uppercased().filter(alphabet.contains).prefix(length))
    }

    /// The whole code as the API expects it, or nil until all eight are typed.
    public static func normalized(_ typed: String) -> String? {
        let code = characters(typed)
        return code.count == length ? String(code) : nil
    }

    /// What the field shows while someone types: upper-cased, with a dash once
    /// a fifth character arrives (or the person types it), so a pasted
    /// "abcd efgh" reads ABCD-EFGH.
    public static func formatted(_ typed: String) -> String {
        let code = characters(typed)
        if code.count == 4, typed.hasSuffix("-") { return String(code) + "-" }
        guard code.count > 4 else { return String(code) }
        return String(code.prefix(4)) + "-" + String(code.dropFirst(4))
    }
}
