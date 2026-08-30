import XCTest
@testable import AnLuongMeeting

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
        XCTAssertTrue(prefs.promptAddendum.contains("chi tiết hơn mức bình thường"))
    }

    func testEachToggleAddsItsOwnLine() {
        var quotes = NoteDetailPreferences()
        quotes.includeQuotes = true
        XCTAssertTrue(quotes.promptAddendum.contains("Trích dẫn nguyên văn"))

        var technical = NoteDetailPreferences()
        technical.includeTechnicalDetails = true
        XCTAssertTrue(technical.promptAddendum.contains("thông số kỹ thuật"))

        var minor = NoteDetailPreferences()
        minor.includeMinorPoints = true
        XCTAssertTrue(minor.promptAddendum.contains("điểm phụ"))
    }

    func testExtraInstructionsAppearVerbatim() {
        var prefs = NoteDetailPreferences()
        prefs.extraInstructions = "Luôn ghi rõ số tiền và đơn vị tiền tệ."
        XCTAssertTrue(prefs.promptAddendum.contains("Luôn ghi rõ số tiền và đơn vị tiền tệ."))
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
        prefs.extraInstructions = "Nhấn mạnh các con số."

        prefs.save(userDefaults: userDefaults)

        XCTAssertEqual(NoteDetailPreferences.loadSaved(userDefaults: userDefaults), prefs)
    }
}
