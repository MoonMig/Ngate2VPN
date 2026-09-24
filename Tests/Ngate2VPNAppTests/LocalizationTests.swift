import XCTest
@testable import Ngate2VPNApp

final class LocalizationTests: XCTestCase {
    private let key = AppLanguage.storageKey
    private var saved: Any?

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.object(forKey: key)
    }

    override func tearDown() {
        if let saved { UserDefaults.standard.set(saved, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
        super.tearDown()
    }

    private func force(_ language: AppLanguage) { UserDefaults.standard.set(language.rawValue, forKey: key) }

    func testForcedRussianAndEnglish() {
        force(.ru)
        XCTAssertEqual(L("Connect All"), "Подключить все")
        force(.en)
        XCTAssertEqual(L("Connect All"), "Connect All")
    }

    func testUnknownKeysAndUserDataPassThroughUnchanged() {
        force(.ru)
        XCTAssertEqual(L("My VPN profile"), "My VPN profile")
        XCTAssertEqual(L("10.66.30.2"), "10.66.30.2")
    }

    func testFormatArguments() {
        force(.ru)
        XCTAssertEqual(L("Error: %@", "boom"), "Ошибка: boom")
        XCTAssertEqual(L("Connection failed with exit code: %d", 7), "Подключение не удалось, код завершения: 7")
        force(.en)
        XCTAssertEqual(L("Error: %@", "boom"), "Error: boom")
    }

    func testSystemFollowsPreferredLanguageOrFallsBackToEnglish() {
        force(.system)
        XCTAssertTrue([AppLanguage.en, .ru].contains(AppLanguage.effective))
    }

    func testTabsAreLocalized() {
        force(.ru)
        XCTAssertEqual(AppTab.allCases.map(\.title), ["Главная", "Журнал", "Настройки"])
        force(.en)
        XCTAssertEqual(AppTab.allCases.map(\.title), ["Home", "Journal", "Settings"])
    }

    func testEveryTunnelStateAndErrorMessageHasARussianTranslation() {
        force(.ru)
        for state in [TunnelState.stopped, .starting, .running, .degraded, .stopping, .failed] {
            XCTAssertNotEqual(state.localizedTitle, state.title, "no translation for state \(state)")
        }
        let errors: [TunnelError] = [
            .invalidCredentials, .certificateNotFound, .invalidCertificateHash, .serverCertificateNameMismatch,
            .networkUnreachable, .connectionRefused, .gatewayUnreachable, .invalidEndpoint, .sessionRefreshFailed,
            .startupTimeout, .twoFactorTimeout, .proxyFailure, .processExited, .launchFailed, .unknown,
        ]
        for error in errors {
            XCTAssertNotEqual(L(error.message), error.message, "no translation for \(error)")
        }
        XCTAssertNotEqual(L(TunnelError.passwordLoginRejectedMessage), TunnelError.passwordLoginRejectedMessage)
    }

    /// A translation that drops or changes a format specifier would crash or
    /// garble the string at runtime.
    func testFormatSpecifiersMatchBetweenKeyAndTranslation() {
        func specifiers(_ text: String) -> [String] {
            var found: [String] = []
            var index = text.startIndex
            while index < text.endIndex {
                if text[index] == "%", let next = text.index(index, offsetBy: 1, limitedBy: text.endIndex), next < text.endIndex {
                    found.append(String(text[next]))
                    index = text.index(after: next)
                } else {
                    index = text.index(after: index)
                }
            }
            return found
        }
        for (key, translation) in Localization.russian where key.contains("%") || translation.contains("%") {
            XCTAssertEqual(specifiers(key), specifiers(translation), key)
        }
    }

    func testNoEmptyTranslationsAndIdentifierKeysExistInBothLanguages() {
        for (key, value) in Localization.russian { XCTAssertFalse(value.isEmpty, key) }
        for key in Localization.english.keys {
            XCTAssertNotNil(Localization.russian[key], "identifier key \(key) has no Russian text")
        }
    }
}
