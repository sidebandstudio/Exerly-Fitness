import XCTest

/// Deleting an account and recovering a password, against the isolated
/// fixture API. Reset codes are read from the fixture's memory outbox; no
/// mail is sent.
final class AccountSecurityUITests: ExerlyUITestCase {
    private let password = "Simulator-Test-123!"

    /// Status of an authenticated GET, without asserting success.
    private func status(_ path: String, token: String) async throws -> Int {
        var check = URLRequest(url: URL(string: fixtureURL + path)!)
        check.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: check)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    private func openDeleteAccount(_ app: XCUIApplication) {
        tap(app.buttons["Profile"], in: app)
        tap(app.buttons["profile.account"], in: app)
        XCTAssertTrue(app.staticTexts["Email and password"].waitForExistence(timeout: 15))
        tap(app.buttons["account.delete"], in: app)
        XCTAssertTrue(app.navigationBars["Delete account"].waitForExistence(timeout: 10))
    }

    private func closeShareSheet(_ app: XCUIApplication) {
        let close = app.buttons["Close"].firstMatch
        if close.exists { close.tap() } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
                .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        }
    }

    func testDeletingAnAccountOffersAnExportAndNeedsItsPassword() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "delete-password")
        let app = launch(resetSession: true)
        signIn(app, email: person.email)
        openDeleteAccount(app)
        XCTAssertTrue(app.staticTexts["Deleting your account can’t be undone."].exists)
        capture(app, "ready-delete-start")

        // Export first, from the same screen.
        tap(app.buttons["account.deleteExport"], in: app)
        XCTAssertTrue(app.buttons["Close"].firstMatch.waitForExistence(timeout: 20))
        capture(app, "ready-delete-export")
        closeShareSheet(app)
        // Closing the share sheet saved nothing, so it doesn't count as an export.
        XCTAssertTrue(app.buttons["Export my data"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Export again"].exists)

        // Nothing to confirm with until a password is typed.
        reveal(app.buttons["account.confirmDelete"], in: app)
        XCTAssertFalse(app.buttons["account.confirmDelete"].isEnabled)
        capture(app, "ready-delete-consequences")

        // A wrong password keeps the account and says why.
        // Return on the password keyboard asks for confirmation, as the button does.
        let field = app.secureTextFields["account.deletePassword"]
        replace(field, with: "not-my-password", in: app)
        app.typeText("\n")
        XCTAssertTrue(app.staticTexts["Delete this account?"].waitForExistence(timeout: 10))
        tap(app.buttons["account.deleteConfirmation.confirm"], in: app)
        // At the largest text the error row starts below the fold.
        let wrong = app.staticTexts["That password is incorrect."]
        reveal(wrong, in: app)
        XCTAssertTrue(wrong.exists || wrong.waitForExistence(timeout: 15))
        capture(app, "ready-delete-wrong-password")
        let alive = try await status("/api/me", token: person.token)
        XCTAssertEqual(alive, 200, "a wrong password deletes nothing and keeps the session")

        // The right password, confirmed once more, deletes it.
        XCTAssertFalse(app.buttons["account.confirmDelete"].isEnabled, "the wrong password was cleared")
        replace(field, with: password, in: app)
        app.typeText("\n")
        XCTAssertTrue(app.staticTexts["Delete this account?"].waitForExistence(timeout: 10))
        tap(app.buttons["account.deleteConfirmation.confirmCancel"], in: app)
        tap(app.buttons["account.confirmDelete"], in: app)
        // The whole warning is readable, at any text size, with both choices.
        let warning = app.staticTexts["You haven’t exported your data. Your Exerly records will be permanently removed."]
        XCTAssertTrue(warning.waitForExistence(timeout: 10))
        capture(app, "ready-delete-confirm")
        let confirm = app.buttons["account.deleteConfirmation.confirm"]
        reveal(confirm, in: app)
        XCTAssertTrue(confirm.isHittable)
        XCTAssertTrue(app.buttons["account.deleteConfirmation.confirmCancel"].isHittable)
        capture(app, "ready-delete-confirm-actions")
        tap(confirm, in: app)
        XCTAssertTrue(app.buttons["I already have an account"].waitForExistence(timeout: 30))
        let leaving = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                                object: app.navigationBars["Delete account"])
        XCTAssertEqual(XCTWaiter().wait(for: [leaving], timeout: 10), .completed)
        waitUntilStill(app.buttons["I already have an account"])
        capture(app, "ready-delete-done")
        let gone = try await status("/api/export", token: person.token)
        XCTAssertEqual(gone, 401)
    }

    func testAPasswordAccountConnectedToAppleDeletesWithItsPasswordAndSignInWithApple() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "delete-apple-too")
        // Launch plans revoke Apple's authorization on deletion; the fixture
        // records the code instead of calling Apple.
        try await control(["linkAppleEmail": person.email, "appleRevocation": true])
        addTeardownBlock { try? await self.control([:]) }
        let app = launch(resetSession: true, environment: [
            "EXERLY_TEST_APPLE_AUTHORIZATION": "synthetic-identity-token synthetic-nonce-0123456789 synthetic-apple-code",
        ])
        signIn(app, email: person.email)
        openDeleteAccount(app)

        let field = app.secureTextFields["account.deletePassword"]
        replace(field, with: password, in: app)
        app.typeText("\n")
        XCTAssertTrue(app.staticTexts["Delete this account?"].waitForExistence(timeout: 10))
        tap(app.buttons["account.deleteConfirmation.confirm"], in: app)

        // The server needs Sign in with Apple as well: the password stays, and
        // Apple is offered to finish.
        let apple = app.buttons["account.appleAuthorization"]
        reveal(apple, in: app)
        XCTAssertTrue(apple.waitForExistence(timeout: 15))
        XCTAssertTrue(apple.isEnabled, "the typed password is kept")
        XCTAssertTrue(field.exists)
        let footer = app.staticTexts["account.deleteFooter"]
        reveal(footer, in: app)
        XCTAssertTrue(footer.label.contains("connected to Apple"), footer.label)
        XCTAssertFalse(app.staticTexts["account.deleteError"].exists)
        capture(app, "ready-delete-apple-too")
        let alive = try await status("/api/me", token: person.token)
        XCTAssertEqual(alive, 200)

        reveal(apple, in: app)
        tap(apple, in: app)
        XCTAssertTrue(app.staticTexts["Delete this account?"].waitForExistence(timeout: 10))
        tap(app.buttons["account.deleteConfirmation.confirm"], in: app)
        XCTAssertTrue(app.buttons["I already have an account"].waitForExistence(timeout: 30))
        let revoked = try await request("GET", "/__test/apple-revocations")
        XCTAssertTrue((revoked["codes"] as? [String] ?? []).contains("synthetic-apple-code"))
        let gone = try await status("/api/export", token: person.token)
        XCTAssertEqual(gone, 401)
    }

    func testForgotPasswordEmailsACodeThatSetsANewPassword() async throws {
        try await control([:])
        let person = try await createAccount(prefix: "reset-password")
        let app = launch(resetSession: true)
        tap(app.buttons["I already have an account"], in: app)
        replace(app.textFields["Email"], with: person.email, in: app)
        dismissKeyboard(app)
        tap(app.buttons["login.forgotPassword"], in: app)
        XCTAssertTrue(app.staticTexts["Reset your password"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["Email"].value as? String, person.email, "the typed email comes along")
        capture(app, "ready-reset-request")
        tap(app.buttons["reset.send"], in: app)
        XCTAssertTrue(app.staticTexts["Check your email"].waitForExistence(timeout: 15))
        capture(app, "ready-reset-code")

        let mail = try await request("GET", "/__test/password-reset-mail?email=\(person.email)")
        let code = try XCTUnwrap(mail["code"] as? String)
        let newPassword = "Brand-New-Passphrase-42"

        // A wrong code is refused and changes nothing.
        let wrongCode = code.hasPrefix("AAAA") ? "BBBB-BBBB" : "AAAA-AAAA"
        replace(app.textFields["Code"], with: wrongCode, in: app)
        replace(app.secureTextFields["New password"], with: newPassword, in: app)
        app.typeText("\n")
        let refused = app.staticTexts["reset.error"]
        reveal(refused, in: app)
        XCTAssertTrue(refused.exists || refused.waitForExistence(timeout: 15))
        XCTAssertTrue(refused.label.hasPrefix("That code is wrong or has expired."), refused.label)
        capture(app, "ready-reset-wrong-code")

        replace(app.textFields["Code"], with: code, in: app)
        dismissKeyboard(app)
        tap(app.buttons["reset.submit"], in: app)
        let notice = app.staticTexts["Password changed. Sign in with your new password."]
        XCTAssertTrue(notice.waitForExistence(timeout: 15))
        XCTAssertEqual(app.textFields["Email"].value as? String, person.email)
        capture(app, "ready-reset-done")
        let ended = try await status("/api/me", token: person.token)
        XCTAssertEqual(ended, 401, "a reset ends every session")

        // The old password no longer works, and says so plainly.
        replace(app.secureTextFields["Password"], with: password, in: app)
        dismissKeyboard(app)
        tap(app.buttons["Log In"], in: app)
        let mismatch = app.staticTexts["That email and password don’t match. Try again, or reset your password."]
        XCTAssertTrue(mismatch.waitForExistence(timeout: 15))
        capture(app, "ready-signin-wrong-password")

        replace(app.secureTextFields["Password"], with: newPassword, in: app)
        dismissKeyboard(app)
        tap(app.buttons["Log In"], in: app)
        XCTAssertTrue(app.navigationBars["Today"].waitForExistence(timeout: 30))
        settleAfterSignIn(app)
    }
}
