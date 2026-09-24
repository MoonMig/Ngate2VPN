import Foundation

/// In-app language selection. `system` follows the macOS preferred languages
/// (Russian if it is the first supported one, otherwise English); `en` / `ru`
/// force a language regardless of the system.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, ru

    var id: String { rawValue }
    static let storageKey = "appLanguage"

    /// The user's choice (defaults to `system`).
    static var stored: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .system
    }

    /// The language actually used for the UI: `.en` or `.ru`.
    static var effective: AppLanguage {
        switch stored {
        case .en, .ru:
            return stored
        case .system:
            for tag in Locale.preferredLanguages {
                if tag.hasPrefix("ru") { return .ru }
                if tag.hasPrefix("en") { return .en }
            }
            return .en
        }
    }
}

/// Localized string for `key`.
///
/// Keys are the English source strings, so an unknown key (a profile name, a
/// dynamic message, anything not in the table) simply comes back unchanged —
/// which makes it safe to pass user data through. Keys with format specifiers
/// (`%@`, `%d`) take their arguments after the key.
///
/// Journal `[SYSTEM]` lines and ngate-client output are deliberately *not*
/// translated: they are diagnostics that are also written to log files and
/// searched by exact wording.
func L(_ key: String, _ args: CVarArg...) -> String {
    let template = Localization.template(for: key, language: AppLanguage.effective)
    return args.isEmpty ? template : String(format: template, arguments: args)
}

enum Localization {
    static func template(for key: String, language: AppLanguage) -> String {
        switch language {
        case .ru:
            return russian[key] ?? english[key] ?? key
        case .en, .system:
            return english[key] ?? key
        }
    }

    /// English text for keys that are identifiers rather than English sentences
    /// (long, multi-line texts). Plain English keys need no entry.
    static let english: [String: String] = [
        "help.body": """
        A client for managing several Ngate VPN tunnels.

        Home
        Turn a tunnel on or off with its switch, or use Connect All / Disconnect All. \
        Right-click a profile to edit, reorder or delete it. Click the IP address of a \
        connected tunnel to copy it.

        Journal
        A live stream of events from all tunnels. Filter by tunnel and by level \
        (Errors / Info / Debug) and show or hide System events.

        Settings
        ngate binary path, auto-connect, pre-warming, error alerts, DNS Helper, \
        theme and language.

        Fast connect
        With Pre-warm on, certificate tunnels are started in advance — keep the token \
        plugged in and Connect takes seconds instead of ~12 s per tunnel.

        Two-factor login
        Approve the prompt in your authenticator app right after connecting: the gateway \
        waits only ~15 s. A missed prompt is retried once.

        Menu bar
        The status icon lists your tunnels and, for connected ones, their IP addresses \
        (click to copy).

        DNS Helper
        Install it once in Settings → DNS Helper; after that split-DNS is applied \
        automatically, without a password prompt.

        Logs
        ~/Library/Application Support/Ngate2VPN/logs/
        """,
    ]

    static let russian: [String: String] = [
        // Tabs
        "Home": "Главная",
        "Journal": "Журнал",
        "Settings": "Настройки",

        // Tunnel states
        "Disconnected": "Отключено",
        "Connecting": "Подключение",
        "Connected": "Подключено",
        "Degraded": "Нестабильно",
        "Disconnecting": "Отключение",
        "Failed": "Ошибка",

        // Home
        "Connect All": "Подключить все",
        "Disconnect All": "Отключить все",
        "New profile": "Новый профиль",
        "Delete Profile?": "Удалить профиль?",
        "Delete": "Удалить",
        "Cancel": "Отмена",
        "This action cannot be undone.": "Это действие нельзя отменить.",
        "No profiles": "Нет профилей",
        "Add Profile": "Добавить профиль",
        "Edit Profile": "Изменить профиль",
        "Move Up": "Выше",
        "Move Down": "Ниже",
        "Delete Profile": "Удалить профиль",
        "Untitled": "Без названия",
        "Copied": "Скопировано",

        // Edit profile
        "Save": "Сохранить",
        "Profile": "Профиль",
        "Name": "Название",
        "Profile name": "Название профиля",
        "Connection": "Подключение",
        "Auto-reconnect": "Автопереподключение",
        "Auth": "Авторизация",
        "Method": "Способ",
        "Certificate": "Сертификат",
        "Login": "Логин",
        "Fingerprint": "Отпечаток",
        "Leave blank to keep": "Пусто — без изменений",
        "Username": "Имя пользователя",
        "Password": "Пароль",
        "Secrets are stored in macOS Keychain and never logged.": "Секреты хранятся в Keychain macOS и не попадают в журнал.",

        // Journal
        "All tunnels": "Все туннели",
        "Errors": "Ошибки",
        "Info": "Инфо",
        "Debug": "Отладка",
        "System": "Система",
        "Copy": "Копировать",
        "Clear": "Очистить",
        "Copy all visible entries": "Копировать все видимые записи",
        "No events": "Нет событий",

        // Settings
        "Application": "Приложение",
        "Binary": "Бинарник",
        "Hide from Dock on close": "Скрывать из Dock при закрытии",
        "Auto-connect on launch": "Автоподключение при запуске",
        "Pre-warm tunnels (faster connect)": "Прогрев туннелей (быстрее подключение)",
        "Notifications": "Уведомления",
        "Show error alerts": "Показывать окна с ошибками",
        "Interface": "Интерфейс",
        "Theme": "Тема",
        "Dark": "Тёмная",
        "Light": "Светлая",
        "Language": "Язык",
        "Status": "Статус",
        "Not installed": "Не установлен",
        "Working…": "Выполняется…",
        "Active": "Активен",
        "Error: %@": "Ошибка: %@",
        "Install": "Установить",
        "Uninstall": "Удалить",
        "Hold Default DNS": "Не менять системный DNS",

        // Tray menu / app menu
        "Open Ngate VPN": "Открыть Ngate VPN",
        "Active connections": "Активные подключения",
        "Settings...": "Настройки…",
        "Settings…": "Настройки…",
        "Quit": "Выйти",
        "Help": "Помощь",
        "Click to copy the IP address": "Нажмите, чтобы скопировать IP-адрес",

        // Alerts: titles
        "Delete Error": "Ошибка удаления",
        "Binary Not Found": "Бинарник не найден",
        "Connection Error": "Ошибка подключения",
        "PIN Required": "Требуется PIN",
        "Password Required": "Требуется пароль",
        "Keychain Error": "Ошибка Keychain",
        "Two-Factor Timeout": "Таймаут двухфакторного подтверждения",
        "Auto-reconnect Paused": "Автопереподключение приостановлено",

        // Alerts: messages
        "Failed to stop tunnel before deletion": "Не удалось остановить туннель перед удалением",
        "VPN client binary not found at:\n%@\n\nUpdate the path in Settings → Application → Binary.":
            "VPN-клиент не найден по пути:\n%@\n\nУкажите путь в Настройки → Приложение → Бинарник.",
        "PIN not found in Keychain. Open the profile and save your PIN first.":
            "PIN не найден в Keychain. Откройте профиль и сначала сохраните PIN.",
        "Password not found in Keychain. Open the profile and save your password first.":
            "Пароль не найден в Keychain. Откройте профиль и сначала сохраните пароль.",
        "Failed to load credentials.": "Не удалось загрузить учётные данные.",
        "The tunnel could not be re-established after %d attempts. Check the network or proxy, then toggle it to try again.":
            "Не удалось восстановить туннель после %d попыток. Проверьте сеть или прокси и включите туннель заново.",
        "Connection failed with exit code: %d": "Подключение не удалось, код завершения: %d",

        // Tunnel errors (alert text)
        "Invalid credentials": "Неверные учётные данные",
        "Login rejected by the gateway. Check the password and that the second-factor prompt was approved — a declined prompt or a temporary lock looks the same.":
            "Шлюз отклонил вход. Проверьте пароль и что запрос второго фактора был подтверждён — отклонённый запрос и временная блокировка выглядят одинаково.",
        "Certificate not found": "Сертификат не найден",
        "Invalid certificate hash": "Неверный отпечаток сертификата",
        "The server's TLS certificate does not match this gateway's host name. The administrator needs to fix the certificate, or the URL is wrong.":
            "TLS-сертификат сервера не соответствует имени шлюза. Администратору нужно исправить сертификат, либо неверен URL.",
        "Network unreachable": "Сеть недоступна",
        "Connection refused": "Соединение отклонено",
        "Gateway unreachable": "Шлюз недоступен",
        "Invalid server URL": "Неверный URL сервера",
        "VPN session was closed by server. Reconnecting…": "Сервер закрыл VPN-сессию. Переподключение…",
        "Startup timed out": "Время запуска истекло",
        "Two-factor confirmation timed out. The gateway waits only ~15 s — approve the login in your authenticator app as soon as the request arrives.":
            "Время подтверждения второго фактора истекло. Шлюз ждёт всего ~15 с — подтверждайте вход в приложении сразу после запроса.",
        "The system proxy is not passing traffic to the gateway. Check the proxy app (or add the gateway to its bypass list).":
            "Системный прокси не пропускает трафик до шлюза. Проверьте приложение-прокси (или добавьте шлюз в его исключения).",
        "Tunnel process exited unexpectedly": "Процесс туннеля неожиданно завершился",
        "Tunnel failed to start": "Не удалось запустить туннель",
        "Unknown tunnel error": "Неизвестная ошибка туннеля",

        // Help panel
        "help.body": """
        VPN-клиент для управления несколькими туннелями Ngate.

        Главная
        Включайте и выключайте туннель переключателем или кнопками «Подключить все» / \
        «Отключить все». Правый клик по профилю — изменить, переставить или удалить. \
        Клик по IP-адресу подключённого туннеля копирует его.

        Журнал
        Поток событий всех туннелей в реальном времени. Фильтр по туннелю и уровню \
        (Ошибки / Инфо / Отладка), события «Система» можно показать или скрыть.

        Настройки
        Путь к бинарнику ngate, автоподключение, прогрев, окна с ошибками, DNS Helper, \
        тема и язык.

        Быстрое подключение
        При включённом прогреве туннели по сертификату запускаются заранее — держите \
        токен вставленным, и подключение занимает секунды вместо ~12 с на туннель.

        Вход с двухфакторным подтверждением
        Подтверждайте запрос в приложении сразу после подключения: шлюз ждёт всего ~15 с. \
        Пропущенный запрос повторяется один раз.

        Меню в строке меню
        Значок в статус-баре показывает туннели и IP-адреса подключённых (клик копирует).

        DNS Helper
        Устанавливается один раз в Настройки → DNS Helper; дальше split-DNS применяется \
        автоматически и без запроса пароля.

        Логи
        ~/Library/Application Support/Ngate2VPN/logs/
        """,
    ]
}
