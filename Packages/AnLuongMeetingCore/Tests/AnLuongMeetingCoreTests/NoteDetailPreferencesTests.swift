import XCTest
@testable import AnLuongMeetingCore

final class NoteDetailPreferencesTests: XCTestCase {
    private var userDefaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "NoteDetailPreferencesTests-\(UUID().uuidString)"
        userDefaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        userDefaults.removePersistentDomain(forName: suiteName)
    }

    func testDefaultPreferencesProduceEmptyAddendum() {
        XCTAssertEqual(NoteDetailPreferences().promptAddendum, "")
    }

    func testDetailedLevelAddsAddendumLine() {
        var prefs = NoteDetailPreferences()
        prefs.level = .detailed
        XCTAssertTrue(prefs.promptAddendum.contains("more detail than usual"))
    }

    func testEachToggleAddsItsOwnLine() {
        var quotes = NoteDetailPreferences()
        quotes.includeQuotes = true
        XCTAssertTrue(quotes.promptAddendum.contains("Quote important statements verbatim"))

        var technical = NoteDetailPreferences()
        technical.includeTechnicalDetails = true
        XCTAssertTrue(technical.promptAddendum.contains("technical specs"))

        var minor = NoteDetailPreferences()
        minor.includeMinorPoints = true
        XCTAssertTrue(minor.promptAddendum.contains("minor points"))
    }

    func testExtraInstructionsAppearVerbatim() {
        var prefs = NoteDetailPreferences()
        prefs.extraInstructions = "Always state amounts with their currency."
        XCTAssertTrue(prefs.promptAddendum.contains("Always state amounts with their currency."))
    }

    func testBlankExtraInstructionsAreIgnored() {
        var prefs = NoteDetailPreferences()
        prefs.extraInstructions = "   \n  "
        XCTAssertEqual(prefs.promptAddendum, "")
    }

    func testLoadSavedReturnsDefaultsWhenNothingStored() {
        XCTAssertEqual(NoteDetailPreferences.loadSaved(userDefaults: userDefaults), NoteDetailPreferences())
    }

    func testSaveThenLoadSavedRoundTrips() {
        var prefs = NoteDetailPreferences()
        prefs.level = .detailed
        prefs.includeQuotes = true
        prefs.extraInstructions = "Emphasize the numbers."

        prefs.save(userDefaults: userDefaults)

        XCTAssertEqual(NoteDetailPreferences.loadSaved(userDefaults: userDefaults), prefs)
    }
}
