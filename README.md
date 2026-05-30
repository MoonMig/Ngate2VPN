# Ngate2VPN

Современный клиент macOS для управления несколькими VPN-туннелями Ngate.
Написан на SwiftUI, с дизайном в духе Shadowrocket и нативной эстетикой
macOS.

> **Статус:** v3.1 — production-ready

---

## Возможности

### Несколько профилей в одном окне
- Управление любым количеством VPN-туннелей из единого интерфейса
- У каждого профиля своё состояние подключения, журнал и учётные данные
- Перетаскивание для изменения порядка, контекстное меню по правому клику
- Редактор профиля открывается как sheet — без перехода из основного окна

### Интерфейс из трёх разделов
- **Главная (Home)** — список профилей с переключателями, Connect All / Disconnect All
- **Журнал (Journal)** — единый поток логов всех туннелей с фильтрацией
- **Настройки (Settings)** — параметры приложения, DNS Helper, тема

Кнопки вкладок размещены прямо в заголовке окна macOS рядом с кнопками управления.

### Светлая и тёмная темы
- Три режима: **System** (как в macOS), **Light**, **Dark**
- Цвета автоматически адаптируются по всему интерфейсу
- Используется нативная палитра macOS с корректным контрастом

### Надёжная обработка соединений
- Автоматический watchdog с умной стратегией повторных попыток
- **Retryable ошибки** → авто-переподключение
- **Критические ошибки** → остановка и уведомление пользователя
- Connect All продолжает подключение остальных туннелей при ошибке одного
- Распознавание более 30 типов ошибок ngate-client

### DNS Helper — split-DNS без боли
Автоматическое создание `/etc/resolver/<domain>` файлов так, чтобы
запросы к корпоративным доменам шли через VPN, а всё остальное —
напрямую. Подробности в разделе [DNS Helper](#dns-helper) ниже.

- **Один диалог пароля** при первоначальной установке — всё остальное silent
- Автоматический подхват DNS-настроек из ответа шлюза
- Автоматическая очистка при выходе и переподключении туннелей
- Toggle **Hold Default DNS** для удержания системного резолвера

### Безопасное хранение данных
- Пароли VPN и PIN-коды хранятся только в macOS Keychain
- Никогда не попадают в логи или открытое хранение
- Защита от утечек через `print` и отладчик
- Generic error messages при ошибках Keychain — без раскрытия деталей

### Полноценное логирование
- Логи по каждому туннелю в разделе Journal
- Единый поток сортируется по времени; системные события не дублируются
- Фильтры: **Errors**, **Info**, **Debug**, **System**
- Логи можно выделять и копировать
- Автопрокрутка к новым событиям
- Многострочный вывод корректно привязывается к туннелям, табы ngate не ломают строки
- Ротация логов (5 МБ) и очистка через 30 дней
- Полностью асинхронная система логирования
- Системные события `[SYSTEM]` несут явный уровень (`Info` / `Warning` / `Error`)
  и окрашиваются по уровню — единый стиль с ngate-строками
- Timestamp формата `dd.MM.yyyy HH:mm:ss.SSS` для всех строк журнала

### Настройки
- **Автоподключение при запуске** — старт всех туннелей при старте
- `ngateconsoleclient` всегда запускается с `-vvvv`: DNS Helper использует
  verbose-вывод для извлечения DNS-настроек шлюза
- **Показывать ошибки** — отключение всплывающих окон
- **Скрывать из Dock при закрытии** — фоновый режим
- **Тема** — System / Light / Dark
- **DNS Helper** — установка / удаление / Hold Default DNS

### Интеграция в трей
- Иконка в статус-баре с цветовой индикацией:
  - Белый — всё отключено
  - Синий — частично подключено
  - Зелёный — всё подключено
- Быстрое меню: открыть, подключить всё, отключить всё, настройки, выход

### Нативное поведение macOS
- Стандартные `NSAlert` для ошибок
- Окно "О программе" с версией
- `Cmd+,` открывает настройки в том же окне
- Запоминается размер и позиция окна
- Минимальный размер окна контролируется
- Меню Help скрыто (нет неактуальной системной справки)

---

## Требования

- **macOS 13 (Ventura)** или новее (тестировалось до macOS Tahoe 26.x)
- Установленный бинарник `ngateconsoleclient`
  (по умолчанию: `/opt/cprongate/ngateconsoleclient`)
- Аккаунт Ngate VPN с:
  - сертификатом (SHA1 + PIN), или
  - логином и паролем

---

## Установка

### Сборка из исходников

```bash
git clone https://github.com/moonMig/Ngate2VPN.git
cd Ngate2VPN
./build-app.sh
open build/Ngate2VPN.app
```

Скрипт `build-app.sh`:
- Запускает `swift build -c release`
- Собирает `.app` bundle в `build/Ngate2VPN.app`
- Подписывает ad-hoc подписью (для production требуется Developer ID)
- Копирует AppIcon если он есть в `Resources/`

### Настройка пути к бинарнику

При первом запуске откройте **Settings → Application → Binary** и укажите
путь к `ngateconsoleclient`. Если файл не найден — появится предупреждение.

---

## Добавление профиля

1. Нажмите **`+`** в правом верхнем углу
2. Заполните:
   - **Name** — имя профиля
   - **URL** — адрес шлюза (например `https://vpn.example.com`)
   - **Auth** — способ авторизации
3. В зависимости от метода:
   - **Certificate** — SHA1-отпечаток + PIN
   - **Login** — логин и пароль
4. Нажмите **Save** — данные шифруются и сохраняются в Keychain

---

## DNS Helper

### Что это и зачем

При подключении к корпоративному VPN типичная задача — направить запросы
для `*.company.local` через VPN, а всё остальное — через обычный DNS
провайдера. macOS поддерживает это через файлы в `/etc/resolver/<domain>`
с содержимым вида `nameserver 10.0.0.1`. Единственная сложность — для
записи в эту папку нужен root.

DNS Helper автоматизирует процесс:
1. При подключении туннеля парсит DNS-настройки из ответа шлюза
2. Создаёт нужные файлы в `/etc/resolver/`
3. Сбрасывает кэш `dscacheutil` и `mDNSResponder`
4. При отключении туннеля — удаляет свои файлы

Toggle **Hold Default DNS** контролирует, перехватывать ли catch-all
резолвер (`/etc/resolver/.`). Включён по умолчанию — системный DNS не
трогается, перехватываются только конкретные домены.

### Архитектура

Без Apple Developer ID невозможно ни использовать `SMAppService.daemon`
(launchd отвергает ad-hoc-подписанные daemon-binaries на macOS Sequoia /
Tahoe), ни `NEDNSSettings` API (требует Network Extension entitlement
выдаваемый Apple). Решение — `sudoers.d` правило:

```
# /etc/sudoers.d/ngate2vpn
<ваш_логин> ALL=(root) NOPASSWD: /usr/local/libexec/ngate2vpn-dns-apply.sh
```

Это правило позволяет конкретному пользователю запускать **ровно один
скрипт** без пароля. Все остальные `sudo` команды по-прежнему требуют
аутентификации.

Helper script `/usr/local/libexec/ngate2vpn-dns-apply.sh` принимает
команды через stdin в простом line-protocol:

```
WRITE example.com 10.0.0.1 10.0.0.2
REMOVE old.example.com
WRITE_DEFAULT 1.1.1.1
REMOVE_DEFAULT
FLUSH
UNINSTALL_SELF example.com other.example.com
```

Каждая команда валидируется regex'ами: домены — `[a-z0-9.-]+`, IP —
`[0-9a-fA-F.:]+`. Никаких `eval` или подстановок аргументов.

### Жизненный цикл

| Действие                            | Диалог пароля? |
|-------------------------------------|----------------|
| Settings → DNS Helper → Install     | ✅ один раз    |
| Подключение туннеля                 | ❌             |
| Отключение туннеля                  | ❌             |
| Quit (Cmd+Q) — авто-очистка         | ❌             |
| Restart после Force Quit            | ❌ (auto-cleanup) |
| Settings → DNS Helper → Uninstall   | ❌             |

При Cmd+Q приложение через `applicationShouldTerminate` ждёт пока async
cleanup удалит все `/etc/resolver/` файлы созданные приложением, потом
завершается. После Force Quit информация о созданных файлах сохраняется
в `~/Library/Application Support/Ngate2VPN/dns-helper-active.flag` —
при следующем запуске приложение их находит и корректно удаляет.

### Безопасность

- `sudoers.d` правило позволяет запуск **ровно одного скрипта** этим
  пользователем
- Helper script установлен как `root:wheel`, mode `700`
- `visudo -cf` валидирует sudoers перед установкой
- Все входные данные валидируются дважды (Swift и bash) через whitelist
  regex
- Никакие пароли не хранятся в Keychain или на диске

---

## Архитектура

```
Ngate2VPN.app/Contents/MacOS/Ngate2VPN
        │
        ├── AppState (@MainActor)
        │   ├── tunnels (модели)
        │   ├── runtime (живые состояния)
        │   ├── DNSPolicyController (агрегатор политик)
        │   └── DNSApplier (применение к /etc/resolver/)
        │
        ├── ProcessRunner (управление ngate-client)
        ├── KeychainSecretStore (VPN credentials)
        └── FileLogger (actor, асинхронные логи)
```

### Основные модули

| Файл                          | Назначение                                                |
|-------------------------------|-----------------------------------------------------------|
| `Ngate2VPNApp.swift`          | Жизненный цикл, AppDelegate, меню, статус-бар             |
| `AppState.swift`              | Состояние туннелей, бизнес-логика, `@MainActor`           |
| `ContentView.swift`           | UI: Home, Journal, Settings                               |
| `NgateOutputParser.swift`     | Pure парсинг stdout ngate-client (классификация ошибок)   |
| `TunnelPersistence.swift`     | UserDefaults persistence для конфигурации профилей        |
| `DNSPolicyController.swift`   | Агрегатор DNS политик от всех туннелей                    |
| `DNSApplier.swift`            | Применение политик через sudoers helper                   |
| `ProcessRunner.swift`         | Запуск и мониторинг ngate-client процессов, secure-config |
| `KeychainSecretStore.swift`   | Сохранение VPN credentials в Keychain                     |
| `FileLogger.swift`            | Асинхронные логи (actor) с ротацией                       |
| `StatusIconManager.swift`     | Иконка в статус-баре                                      |

### Конкурентность

- `AppState` — `@MainActor`, единый источник истины для UI
- `FileLogger` — Swift actor, изолирующий доступ к диску
- `DNSApplier` — `@MainActor` для UI-state, `Task.detached` для shell-вызовов
- `ProcessRunner` — отдельные DispatchQueues для каждого туннеля
- `Combine` — реактивные обновления политик и состояний

---

## Классификация ошибок

| Ошибка                  | Retry | Поведение                |
|-------------------------|-------|--------------------------|
| `networkUnreachable`    | ✅    | автоматический повтор    |
| `connectionRefused`     | ✅    | автоматический повтор    |
| `gatewayUnreachable`    | ✅    | автоматический повтор    |
| `startupTimeout`        | ✅    | автоматический повтор    |
| `sessionRefreshFailed`  | ✅    | автоматический повтор    |
| `invalidCredentials`    | ❌    | остановка + уведомление  |
| `certificateNotFound`   | ❌    | остановка + уведомление  |
| `invalidCertificateHash`| ❌    | остановка + уведомление  |
| `invalidEndpoint`       | ❌    | остановка + уведомление  |

---

## Устранение проблем

### "Binary not found"
Проверьте путь в Settings → Application → Binary. Файл должен быть
исполняемым (`chmod +x`).

### "Invalid server URL"
URL должен включать схему: `https://vpn.example.com`. Без `https://` —
ошибка.

### "Invalid credentials"
Для cert-auth: SHA1 сертификата + PIN. Для login-auth: логин и пароль.
Проверьте всё внимательно — после трёх ошибок шлюз может временно
заблокировать аккаунт.

### Постоянные переподключения
Проблемы с сетью на стороне клиента или блокировка нужного порта
(обычно UDP/1194 или TCP/443). Проверьте Journal с фильтром Errors —
там точная причина.

### DNS Helper не применяет политику
1. Проверьте Journal на ошибки от `[SYSTEM]` событий
2. Убедитесь что `ngate2vpn-dns-apply.sh` существует:
   ```
   ls -la /usr/local/libexec/ngate2vpn-dns-apply.sh
   ```
3. Проверьте sudoers entry:
   ```
   sudo cat /etc/sudoers.d/ngate2vpn
   ```
4. Если что-то не так — `Settings → DNS Helper → Uninstall → Install`

### `/etc/resolver/` остался непустым после деинсталляции
Это могут быть файлы от других приложений или старых версий. Просмотрите
содержимое — каждый файл это просто `nameserver <ip>`. Для безопасной
очистки удалите вручную через `sudo rm`.

---

## Конфиденциальность и безопасность

- **Никакой телеметрии.** Приложение не отправляет данные нигде.
- **Никакой аналитики.** Не используется ни Sentry, ни Crashlytics, ни любой другой агент.
- **Все данные локальны.** VPN credentials — Keychain, логи — `~/Library/Logs/Ngate2VPN/`,
  настройки — UserDefaults и Application Support.
- **Минимум привилегий.** Root нужен только для записи в `/etc/resolver/`,
  и только через узкое sudoers правило на конкретный helper script.
- **Generic error messages.** Ошибки Keychain никогда не раскрывают
  внутренние OSStatus коды или системные детали.

---

## Сборка production-версии

Для распространения вне dev-машины потребуется:

1. **Apple Developer ID Application** сертификат ($99 / год)
2. Заменить ad-hoc `--sign -` в `build-app.sh` на свой Developer ID
3. Notarization через `notarytool`
4. Stapling: `xcrun stapler staple build/Ngate2VPN.app`

Без этих шагов macOS Gatekeeper будет жаловаться на "недоверенный
разработчик" при первом запуске на чужой машине.

## Публикация на GitHub Releases

Для приватного репозитория удобнее всего использовать GitHub CLI:

```bash
brew install gh
export GH_TOKEN="github_pat_..."
./Scripts/publish_github_release.sh
```

Fine-grained personal access token должен иметь доступ к репозиторию
`moonMig/Ngate2VPN` и permissions:
- **Contents: Read and write**
- **Metadata: Read-only**

Скрипт требует существующий чистый git-репозиторий с настроенным `origin`,
проверяет ветку и remote, пушит текущую ветку, собирает `Ngate2VPN.app`,
архивирует приложение в zip и создаёт GitHub Release с тегом вида `v3.0`.

---

## Журнал изменений

Подробности по версиям — в [CHANGELOG.md](CHANGELOG.md).

---

## Вклад в проект

1. Создайте issue с описанием проблемы или фичи
2. Fork репозитория, создайте feature-ветку
3. Соблюдайте существующий стиль кода (Swift API Design Guidelines)
4. Добавляйте unit-тесты для логики, требующей проверки
5. Pull Request с понятным описанием изменений

---

## Благодарности

- Вдохновение UX: Shadowrocket
- Ngate-client как backend
- Apple HIG для соответствия macOS-стилю

---

## Лицензия

[Укажите лицензию — MIT, Apache-2.0 или другую]
