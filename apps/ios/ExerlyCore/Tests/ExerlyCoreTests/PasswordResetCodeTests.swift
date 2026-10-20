import Testing
@testable import ExerlyCore

@Suite struct PasswordResetCodeTests {
    @Test func typedCodesBecomeTheMailedForm() {
        #expect(PasswordResetCode.normalized("ABCD-EFGH") == "ABCDEFGH")
        #expect(PasswordResetCode.normalized(" abcd efgh ") == "ABCDEFGH")
        #expect(PasswordResetCode.normalized("abcd—efgh\n") == "ABCDEFGH")
        #expect(PasswordResetCode.normalized("ABCD-EFG") == nil, "seven characters")
        #expect(PasswordResetCode.normalized("") == nil)
    }

    @Test func charactersNoCodeHoldsAreDropped() {
        // 0, O, 1 and I are never in a code, so a stray one doesn't count.
        #expect(PasswordResetCode.normalized("A0BCD1EFGHI") == "ABCDEFGH")
        #expect(PasswordResetCode.normalized("ABCD-EFGO") == nil)
        #expect(PasswordResetCode.normalized("ABCDEFGHJK") == "ABCDEFGH", "extra characters are ignored")
    }

    @Test func theFieldShowsTheDashOnceItHelps() {
        #expect(PasswordResetCode.formatted("abc") == "ABC")
        #expect(PasswordResetCode.formatted("abcd") == "ABCD")
        #expect(PasswordResetCode.formatted("abcde") == "ABCD-E")
        #expect(PasswordResetCode.formatted("ABCD-") == "ABCD-", "a dash the person typed stays")
        #expect(PasswordResetCode.formatted("ABC-") == "ABC")
        #expect(PasswordResetCode.formatted("abcd efgh") == "ABCD-EFGH")
        #expect(PasswordResetCode.formatted("ABCD-EFGHJKL") == "ABCD-EFGH")
    }
}
