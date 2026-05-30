# Changelog

Все значимые изменения проекта документируются в этом файле.

Формат основан на [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/),
проект следует [Semantic Versioning](https://semver.org/lang/ru/).

## [3.8] — 2026-05-30

### Исправлено
- **Фильтр уровня в Журнале не применялся к `[SYSTEM]`-событиям.** При выборе фильтра «Errors» отображались все системные события включая Info/Warning. Теперь `[SYSTEM]`-строки проходят через тот же фильтр уровня, что и обычные строки.

## [3.7] — 2026-05-30

### Удалено (мёртвый код)
- `ErrorLog.snapshot()` — нигде не вызывался.
- `KeychainSecretStoreError.internalStatus` — нигде не использовалось.
- `PersistedState.CodingKeys` и кастомный `init(from:)` — полностью повторяли автосинтез Swift.

## [3.6] — 2026-05-30

### Удалено (мёртвый код)
- `updateStatusBarAppearance()` и `dismissErrorNotification()` в `AppDelegate` — нигде не вызывались.
- `lastAlertDismissedAt: Date?` — только записывалось, никогда не читалось.
- `applyCurrentPolicy()` — однострочная обёртка, заменена прямым вызовом.
- `DNSHelperState.awaitingUserApproval` — legacy case от SMAppService, никогда не устанавливался; убран вместе со всеми обработчиками в ContentView.
- `struct TitleBar` — мёртвая структура, заменена `TitlebarTabView` через `NSToolbar`.

### Исправлено
- `quit()` в трей-меню: убраны избыточные `persist()` и `shutdown()` перед `terminate(nil)`, которые гонялись с DNS cleanup в `applicationShouldTerminate`.

## [3.5] — 2026-05-30

### Удалено (мёртвый код)
- Поля `lastExitCode`, `lastLogAt`, `lastOnlineAt` в `TunnelRuntimeState` — только записывались, нигде не читались.
- Метод `appendBulkLog()` — нигде не вызывался.
- Дублирующий паттерн `"password combination has been tried"` в `NgateOutputParser` — полностью покрывался предыдущим паттерном.
- Trivial `do { try } catch { throw }` в `TunnelProcess.start()` — заменён на прямой `try`.

## [3.4] — 2026-05-30

### Исправлено
- **Критическая ошибка watchdog:** при удалении туннеля во время `await` в `runWatchdogPass` код выполнял `return` вместо `continue`, что отменяло только что пересозданный watchdog task и останавливало наблюдение за всеми оставшимися туннелями.
- **Мёртвый код:** удалён неиспользуемый метод `updateMinWidth` в `AppDelegate`.

## [3.3] — 2026-05-30

### Улучшено
- Область hover-подсветки строки профиля на вкладке «Главная» расширена до полной ширины контейнера.

## [3.2] — 2026-05-30

### Исправлено
- **`WRITE_DEFAULT` никогда не создавал рабочий файл default-резолвера.**
  Прежняя реализация пыталась создать файл через `mv tmp /etc/resolver/.`,
  но на HFS+/APFS ядро всегда резолвит `.` в саму директорию — в результате
  создавался файл `..tmp`, который `mDNSResponder` игнорировал. `REMOVE_DEFAULT`
  (`rm -f "/etc/resolver/."`) также был no-op. Согласно man resolver(5), default
  DNS — это `resolv.conf` / primary DNS configuration системы; `/etc/resolver/`
  предназначен только для per-domain роутинга. Реализация переписана:
  `WRITE_DEFAULT` теперь вызывает `networksetup -setdnsservers` на всех активных
  сетевых сервисах, `REMOVE_DEFAULT` восстанавливает DHCP DNS через
  `networksetup -setdnsservers "Empty"`.
- **`UNINSTALL_SELF` не восстанавливал DNS при деинсталляции.**
  При удалении DNS Helper вызов `rm -f "/etc/resolver/."` был no-op и DNS
  через `networksetup` не восстанавливался. Теперь при деинсталляции перед
  `UNINSTALL_SELF` автоматически отправляется `REMOVE_DEFAULT` если `defaultInstalled`.
- **Проверка `fileExists("/etc/resolver/.")` всегда возвращала `true`.**
  В `apply()` проверка существования default-resolver файла использовала путь
  `/etc/resolver/.`, который является директорией, а не файлом. Убрана из
  условия досрочного возврата.
- **Мёртвый код удалён из `AppState` и `StatusIconManager`.**
  Удалены: `enum ConnectAllFailurePolicy` и `connectAllFailurePolicy` (нигде
  не читались), `@Published var autoScrollLogs` (auto-scroll работал независимо
  через `wasNearBottom`), `@Published var selectedLogTunnelID` (JournalView
  использовал собственный локальный state), метод `toggleWindow()` в
  `StatusIconManager` (постил уведомление без единого подписчика),
  `statusBarButtonClicked()` в AppDelegate (status item с меню никогда
  не вызывал action).
- **Вотчдог останавливался целиком при отсутствии runtime-записи одного туннеля.**
  `runWatchdogPass` при `runtime[tunnelID] == nil` вызывал `watchdogTask?.cancel()`
  и `return`, прерывая мониторинг всех туннелей. Исправлено на `continue`.
- **`runHelper` мог заблокировать DNS-политику навсегда.**
  `Process.waitUntilExit()` без таймаута позволял зависшему helper-скрипту
  держать `policyApplyInProgress = true` бесконечно. Добавлен 10-секундный
  watchdog через `DispatchWorkItem`.
- **Версия в панели «О программе» была захардкожена отдельно от `build-app.sh`.**
  Теперь читается из `Bundle.main.infoDictionary["CFBundleShortVersionString"]`
  — единственный источник правды.
- **Иконка трея невидима на светлом menu bar при отключённых туннелях.**
  `NSColor.white` заменён на `NSColor.secondaryLabelColor` — адаптируется к
  теме оформления.

## [3.1] — 2026-05-30

### Исправлено
- **При повторном запуске из `.app` поверх трея появлялось пустое окно
  «Ngate2VPN Placeholder».** `applicationShouldHandleReopen` возвращал `true`,
  что давало AppKit сигнал применять стандартную логику восстановления сцен.
  AppKit послушно восстанавливал все ранее закрытые SwiftUI Window-сцены,
  включая служебный placeholder (закрытый при первом запуске, но не
  освобождённый). Теперь метод возвращает `false` — реактивация обрабатывается
  самостоятельно через `showMainWindow()`, AppKit больше не вмешивается.
  Дополнительно добавлена явная проверка-закрытие placeholder на входе в метод.

## [3.0] — 2026-05-30

### Исправлено
- **DNS Helper не работал после перезапуска приложения без захода в Settings.**
  `DNSApplier` был объявлен как `lazy var` и инициализировался только при первом
  обращении к вкладке Settings. Если пользователь после рестарта не заходил
  в Settings, подписка на изменения policy никогда не устанавливалась, и файлы
  `/etc/resolver/` не создавались, даже когда туннель успешно подключался.
  Теперь `DNSApplier` инициализируется в `AppState.init()` независимо от UI.
- **`holdDefaultDNS` не синхронизировался при старте приложения.**
  После рестарта `DNSPolicyController.holdDefaultDNS` использовал дефолтное
  значение `true`, игнорируя то, что сохранил пользователь в UserDefaults, —
  до тех пор пока Settings не открывались. Теперь значение читается из
  UserDefaults напрямую в `AppState.init()` до первого применения policy.
- **DNS Helper переставал работать после долгого сна / смены сети.**
  `apply()` пропускал перезапись файлов если `writtenScopedResolvers` совпадал
  с целевым состоянием, не проверяя реальное наличие файлов на диске. Если
  macOS удалял файлы `/etc/resolver/` при смене сетевого интерфейса или
  пробуждении после глубокого сна, они больше не пересоздавались. Добавлена
  проверка через `FileManager.fileExists` перед досрочным возвратом.
- **DNS Helper не восстанавливал файлы когда туннель выживал после сна.**
  Если ngate-процесс не умирал во время сна (переподключался внутренне),
  `dnsPolicy` не менялся, `$policy` не публиковался и `apply()` не вызывался
  совсем. Теперь при каждом переходе туннеля в `.running` вызывается
  `reapplyCurrentPolicy()`, который проверяет и при необходимости восстанавливает
  файлы.
- **Дублирование записей `[SYSTEM] DNS Helper: policy applied` в логах.**
  `reapplyCurrentPolicy()` сбрасывал `writtenScopedResolvers` перед постановкой
  в очередь. Если subscription-driven `apply()` уже успевал отработать раньше,
  второй вызов видел расхождение и писал файлы снова, производя дубликат записи.
  Теперь очистка кеша убрана — проверка существования файлов в `apply()`
  обеспечивает нужное поведение без побочных эффектов.
- **Ошибка "Unable to correctly logout from remote gate. VPN session closed."
  отображалась как "Error 0".** Парсер не распознавал эту строку, `lastError`
  не выставлялся, и при выходе ngate с кодом 0 показывался бессмысленный
  попап "Connection failed with exit code: 0". Теперь паттерн добавлен в
  группу `sessionRefreshFailed` (retryable): watchdog тихо переподключается,
  попап не отвлекает пользователя.

### Добавлено
- **Уровни логов для системных событий `[SYSTEM]`.** Каждое системное событие
  теперь несёт явный уровень (`Info` / `Warning` / `Error` / `Critical`)
  по аналогии с форматом ngate. Тег `[SYSTEM]` остаётся оранжевым, тело
  строки окрашивается согласно уровню: красный для ошибок, оранжевый для
  предупреждений, нейтральный для Info.
- **Выравнивание уровней в столбик.** Слово уровня дополняется пробелами до
  ширины самого длинного (`Critical` = 8 символов), чтобы тело сообщения
  начиналось в одном столбце во всех строках — аналогично поведению
  `ngateconsoleclient` в моноширинном шрифте журнала.
- **Миллисекунды в timestamp системных логов.** Формат изменён с
  `dd.MM.yyyy HH:mm:ss` на `dd.MM.yyyy HH:mm:ss.SSS`.

### Изменено
- **Формат даты в логах изменён с `yyyy-MM-dd` на `dd.MM.yyyy`.**
  Применяется ко всем строкам журнала: и к ngate-выводу (prefix), и к
  системным событиям `[SYSTEM]`. Сортировка в журнале корректно работает
  через внутреннее преобразование компонентов.

## [2.40] — 2026-05-28

### Исправлено
- **`ngateconsoleclient` снова всегда запускается с `-vvvv`.** DNS Helper
  извлекает `DNSs` / `SearchDomains` из verbose-вывода шлюза, поэтому
  настройка отключения подробных логов была некорректной и удалена из UI.
- **DNS Helper больше не требует reinstall только из-за замены `.app`.**
  Убрана привязка установленного helper-а к inode/creation date текущего
  bundle: наличие helper script и sudoers rule достаточно для возобновления
  работы после перезапуска.
- **Применение DNS policy сериализовано.** Быстрые изменения policy больше
  не запускают несколько overlapping helper-вызовов, которые могли завершиться
  не по порядку и оставить `/etc/resolver` в устаревшем состоянии.
- **Журнал корректно сортируется после полуночи.** Live-строки теперь несут
  полный `yyyy-MM-dd HH:mm:ss` timestamp, поэтому новые события не сортируются
  выше старых `23:xx` строк и не выглядят пропавшими.

### Изменено
- Обновлены версия приложения, README и release defaults до `2.40`.

## [2.39] — 2026-05-14

### Исправлено
- **Бесконечный retry при fatal ошибке `No certificates acquired by SHA1
  hash`.** Регрессия от 2.26. В 2.26 я добавил маркер
  `"vpn session destroyed"` к группе `sessionRefreshFailed`
  (retryable), полагая что эту строку ngate печатает только при
  server-driven graceful disconnect. На самом деле это
  **finalization event** который ngate выводит при разрыве сессии
  **любого** происхождения, включая fatal ошибки. В сценарии с
  отсутствующим клиентским сертификатом порядок строк такой:
  ```
  Critical  No certificates acquired by SHA1 hash     ← certificateNotFound (non-retryable)
  Debug     VPN session destroyed.                    ← перезаписывало на retryable
  ```
  Поскольку classifier'у скармливаются все строки и `lastError`
  обновляется при каждом hit'е, retryable классификация
  затирала правильную non-retryable и watchdog уходил в
  бесконечный retry loop. Сейчас `"vpn session destroyed"` убран
  из паттернов. Genuine server-driven disconnects по-прежнему
  ловятся через `RefreshTransaction`, `session closed by server`
  и `VPN session closed` + `unexpected status code` — эти маркеры
  предшествуют `session destroyed` и устанавливают правильную
  retryable классификацию первыми.

## [2.38] — 2026-05-13

### Изменено
- **Cleanup после серии правок App menu (2.28–2.37).** Удалён мёртвый
  код, оставшийся после поэтапной эволюции решения:
  - `reapplyMenuOnActivate(_:)` handler и его регистрация на
    `NSApplication.didBecomeActiveNotification` — оба превратились в
    no-op после того как все menu customizations переехали в
    SwiftUI `.commands { ... }` (Settings, Help, Services
    replacement) или в one-shot About swizzle. Observer'а больше
    нет, метода больше нет.
  - Добавлен поясняющий комментарий к `Window` placeholder scene
    в App body — почему она там и почему не `Settings`.

  Никаких функциональных изменений; чистая зачистка legacy.

## [2.37] — 2026-05-13

### Исправлено
- **Закрытие главного окна крестиком терминировало приложение
  (регрессия 2.34).** Замена `Settings { EmptyView() }` scene на
  `Window` placeholder scene изменила то, как SwiftUI считает
  "последнее окно": ранее Settings scene не учитывалось в этом
  подсчёте, а Window — учитывается. SwiftUI применял default
  policy "закрытие последнего окна → quit". Сейчас реализован
  `applicationShouldTerminateAfterLastWindowClosed → false` —
  приложение остаётся работать в tray как и раньше,
  `mainWindowWillClose` переключает activation policy на
  `.accessory`.

- **Services submenu возвращался после удаления.** SwiftUI's
  command system пересобирает App menu на своём расписании
  (после обновлений `CommandGroup` и определённых activation
  events), повторно вставляя Services даже после нашего
  `applyMenuCustomizations` swept. Сейчас AppDelegate стал
  `NSMenuDelegate` для App submenu, и в `menuNeedsUpdate(_:)`
  (вызывается AppKit'ом непосредственно перед показом меню)
  выполняется зачистка Services. Логика вынесена в
  `stripServicesFromAppMenu(_:)` и переиспользуется обоими
  путями.

## [2.36] — 2026-05-13

### Исправлено
- **Стрэй "NSMenuItem" в App menu вместо пункта Settings…** В 2.35
  Settings вставлялся через AppKit (`fixupAppMenu` создавал
  `NSMenuItem(title: "Settings…", action: openSettings, ...)` и
  размещал его по индексу). Этот код иногда срабатывал на
  частично-уже-настроенном menu, в результате чего отрисовывался
  безымянный item с дефолтным `NSMenuItem` описанием класса в
  качестве title. Сейчас Settings вставляется через
  **SwiftUI `CommandGroup(after: .appInfo)`** в App body — это
  документированный API, ставит item в правильную позицию и
  диспатчит клики напрямую в `AppDelegate.openSettings()`
  независимо от того, какое окно сейчас key. `fixupAppMenu` ужат
  до удаления Services (Settings из него убран). Доступ к
  `openSettings` повышен до `internal` (`@objc func` без
  `private`), чтобы SwiftUI Button мог вызвать его через
  `AppDelegate.shared?.openSettings()`.

## [2.35] — 2026-05-13

### Исправлено
- **Settings… пункт вернулся в App menu.** После замены SwiftUI
  `Settings` scene на безобидную `Window` placeholder scene в 2.34,
  пункт "Settings…" пропал из App menu (его автоматически создавала
  именно та scene). Сейчас мы вставляем item сами в `fixupAppMenu`:
  стандартная позиция (после About и сепаратора), shortcut ⌘,
  target=AppDelegate.openSettings. Метод идемпотентный — при
  re-applies на didBecomeActive не плодит дубликаты.

### Удалено
- **Подменю Services убрано из App menu.** Мы не предоставляем
  никаких NSServices, так что auto-injected пункт был мёртвым
  весом. `fixupAppMenu` удаляет его и одну смежную separator-строку
  чтобы меню выглядело компактно.

## [2.34] — 2026-05-13

### Исправлено
- **Settings из menu bar открывал пустое окно когда About panel
  оставался открытым.** Диагностика 2.33 показала что наш
  `rerouteSettingsMenuItem` срабатывал и переписывал menu item на
  `openSettings`, но при кликe Settings когда About panel был
  current key window, AppKit отправлял menu command не через
  target/action item'а, а **через responder chain key window'а**.
  Цепочка проходила через SwiftUI's SceneOpener, который видел
  Settings scene в App body (`Settings { EmptyView() }`) и открывал
  её отдельным окном — отсюда пустое окно с EmptyView внутри.
  Сейчас `Settings { … }` scene заменена на безобидную `Window`
  placeholder scene без Settings-handler'а — SceneOpener больше
  не имеет куда роутить Settings, responder chain falls through к
  application delegate, и наш `openSettings` срабатывает
  независимо от того какое окно сейчас key. Placeholder window
  автоматически закрывается при запуске чтобы не мозолить глаза
  в Window menu.

## [2.33] — 2026-05-13

### Исправлено
- **Settings из menu bar после About показывал пустое окно.** Гонка в
  `openSettings`: сперва устанавливался `selectedTab = .settings`,
  потом через `DispatchQueue.main.async` (отложенный на следующий
  runloop tick) приводилось окно на передний план. Между этими
  событиями SwiftUI успевал перерендерить ContentView в момент,
  когда window ещё был не key (особенно после закрытия About panel'а,
  который притягивал к себе key-window status'а), что иногда
  выглядело как пустое окно. Сейчас порядок инвертирован:
  `showMainWindow()` зовётся **до** мутации `selectedTab`, и сам
  показ окна синхронный (`DispatchQueue.main.async` оттуда убран —
  AppDelegate уже на main actor'е, лишний hop не нужен). То же
  изменение в `openMainWindowToHome`.

## [2.32] — 2026-05-13

### Изменено
- **Cleanup после серии правок About panel.** Убраны: диагностические
  `NSLog` с префиксом `[ABOUT-DIAG2]`, поле `originalAboutPanelIMP`
  и метод `presentStockAboutPanel(options:)`. Оригинальная IMP
  сохранялась "на всякий случай для будущего fallback'а", но
  фактически не использовалась — `showAboutPanel()` зовёт другой
  Obj-C selector (`orderFrontStandardAboutPanelWithOptions:`), который
  мы не свизлили. Документация в `installAboutPanelSwizzle` обновлена
  чтобы отражать финальную минимальную форму решения.

## [2.31] — 2026-05-13

### Исправлено
- **About panel наконец стабильно показывает кастомную версию + credits.**
  Предыдущие попытки 2.28–2.30 (переcetting target/action, удаление
  и вставка нашего menu item'а, async dispatch'и) не работали потому
  что AppKit при выборе "About …" из App menu вызывает
  `NSApplication.orderFrontStandardAboutPanel:` **напрямую**, минуя
  target/action прикреплённый к menu item'у. Диагностика подтвердила:
  пункт меню с правильным action остаётся на месте, но при клике наш
  handler не вызывается. Сейчас перехват сделан **на уровне Obj-C
  runtime** через method swizzling: подменена реализация
  `NSApplication.orderFrontStandardAboutPanel:` на нашу. Перехват
  работает для всех путей вызова — menu bar, Dock right-click,
  AppleScript, Spotlight. Оригинальная IMP сохраняется до swizzle'а
  и вызывается из нашего handler'а через `unsafeBitCast`, чтобы
  показать стандартный panel с нашими `.applicationVersion`,
  `.credits` и пустым "Version" key.

## [2.30] — 2026-05-06

### Исправлено
- **About post-tray (третий заход).** В 2.29 я удалял системный
  About item и вставлял свой — но делал это sync прямо в
  `applicationDidFinishLaunching`. SwiftUI настраивает default
  main menu **позже** этого момента (на своём lifecycle tick),
  и его setup перезаписывал нашу вставку — наш custom item
  затирался, оставался системный с "(1)" и без credits.
  Аналогично, в `reapplyMenuOnActivate` мы могли срабатывать
  до того как AppKit закончил menu work для активации.
  Сейчас обе точки используют `DispatchQueue.main.async` —
  отправляют работу в следующий runloop tick, после того как
  SwiftUI/AppKit закончит свои manipulations. Это та же
  схема что уже работает для Help menu с 2.14.

## [2.29] — 2026-05-06

### Исправлено
- **About после возврата из tray (повторный фикс).** В 2.28 решение
  через observer на `didBecomeActiveNotification` оказалось
  недостаточным: AppKit продолжал откатывать наш `target`/`action`
  на стандартном About item даже после нашего re-apply'а — момент
  отката приходился между observer'ом и кликом юзера. Сейчас
  `customizeAboutPanel` полностью **удаляет** системный About item
  (созданный AppKit'ом) и **вставляет** свой собственный с
  target'ом на наш AppDelegate. AppKit не трогает items которые
  не он создавал, так что наш About остаётся стабильным независимо
  от циклов активации.

## [2.28] — 2026-05-06

### Исправлено
- **About panel показывал старую версию и build "(1)" после возврата
  из tray.** При сворачивании окна, переходе в режим status-bar
  только и обратной активации, AppKit пересобирал часть main menu
  и наш кастомизированный `About …` item возвращался к системному
  default'у — открывал стандартный About с CFBundleShortVersionString
  из Info.plist (закреплено `1`) вместо нашей `showAboutPanel()`,
  где живёт правильная версия + credits с ссылкой на @H3mul.
  Сейчас наблюдается `NSApplication.didBecomeActiveNotification`
  и при каждой активации повторно применяются `customizeAboutPanel`
  и `rerouteSettingsMenuItem` — идемпотентные операции, безопасные
  для многократного вызова. Help menu не затрагивается, поскольку
  с 2.14 он управляется SwiftUI'ской `CommandGroup(replacing: .help)`
  и не страдает от AppKit re-injection.

## [2.27] — 2026-05-06

### Добавлено
- **Атрибуция автора в About panel.** Под номером версии теперь
  отображается строка "Developed by @H3mul" с кликабельной ссылкой
  `tg://H3mul`, открывающей чат в Telegram (если приложение
  установлено).

## [2.26] — 2026-05-06

### Добавлено
- **Распознавание ошибки "VPN session destroyed".** Раньше при
  принудительном разрыве сессии шлюзом (idle timeout, force
  disconnect администратором, рестарт сервера) ngate exit'ил с
  кодом 0, но `lastError` оставался unset — fallback показывал
  пользователю невнятное "Connection failed with exit code: 0".
  Теперь паттерн `"vpn session destroyed"` распознаётся как
  `TunnelError.sessionRefreshFailed` (retryable) — то же поведение
  что для `session closed by server`. Пользователь видит сообщение
  "VPN session was closed by server. Reconnecting…" и watchdog
  автоматически инициирует переподключение.

## [2.25] — 2026-05-06

### Изменено
- **Дата сохраняется в on-disk логах, скрыта из UI.** До 2.24 в файлы
  писались строки в том же укороченном формате что и в журнале UI
  (`HH:mm:ss[.mmm] message`) — без даты, что делало архивные логи
  бесполезными после rotation/смены дня. Теперь:
  - **In-memory journal** — компактный формат как в 2.24, без даты.
  - **On-disk** (`~/Library/Application Support/NgateVPN/logs/`) —
    каждая строка получает префикс `yyyy-MM-dd `. Например
    `2026-05-07 00:57:27.325 Debug …` или `2026-05-07 00:57:02
    [SYSTEM] [profile] message`.

  `[SYSTEM]` события без привязки к туннелю (например DNS Helper) и
  раньше попадали в Console.app через `NSLog` с полной датой —
  поведение не изменилось.

## [2.24] — 2026-05-06

### Изменено
- **Унифицированный формат timestamp'а в журнале.** Раньше формат
  плавал: ngate-строки писались как `May 7 00:42:00.722 Debug …`,
  system-строки от `appendSystemLog` приходили без timestamp'а
  (`[SYSTEM] [profile] message`), а от `appendBulkSystemLog` — со
  скобочным `[00:42:00] [SYSTEM] message`. Теперь:
  - **ngate-строки**: префикс `<Month> <D>` отсекается, остаётся
    `00:42:00.722 Debug …`. Полная дата всё равно есть в имени
    on-disk log файла.
  - **system-строки** (оба helper'а): timestamp ставится **впереди**
    без скобок, в том же формате что и у ngate, но без миллисекунд:
    `00:42:00 [SYSTEM] [profile] …`.
  Журнал читается единым потоком — все entry начинаются с одинакового
  `HH:mm:ss`. `timestampKey` для merge-sort упрощён до одного case.

## [2.23] — 2026-05-06

### Исправлено
- **Двойные timestamp'ы в журнале.** Каждая строка от ngate уже
  содержит свой собственный timestamp с миллисекундной точностью
  (`May 7 00:42:00.722 Debug …`), а наш `appendLog` сверху клеил ещё
  и короткий `[HH:mm:ss]` — отсюда дубликат вида
  `[00:42:00] May 7 00:42:00.722 Debug …`. Теперь:
  - **Строки от ngate** — оставляются как есть, с их точным
    миллисекундным timestamp'ом.
  - **System-сообщения** (`appendSystemLog` / `appendBulkSystemLog`) —
    префиксятся нашим `[HH:mm:ss] [SYSTEM] …` как раньше.

  Sort-логика в журнале (используется в режиме All tunnels +
  System) обновлена чтобы понимать оба формата timestamp'ов и
  корректно мерджить две shape'ы при отображении.

## [2.22] — 2026-05-06

### Исправлено
- **DNS Helper после переустановки приложения — повторное исправление.**
  Подход 2.20 (UUID в UserDefaults + marker file) не работал: macOS
  хранит UserDefaults в `~/Library/Preferences/com.ngate2vpn.app.plist`
  отдельно от `.app` bundle, поэтому при удалении и установке нового
  бандла UUID в UserDefaults сохранялся → IDs совпадали → ложный
  negative. Теперь идентификатором установки служит **fingerprint
  главного бинарника `.app` bundle** — inode номер + creation date
  файла `Ngate2VPN.app/Contents/MacOS/Ngate2VPN`. Эти параметры
  меняются при любой замене файла (пересборка, drag-and-drop, скачивание
  новой версии). Marker file сохраняет fingerprint на момент install,
  и при следующем запуске мы сравниваем с актуальным значением:
  если отличается → переходим в `.error` с предложением переустановить.

### Известный артефакт обновления
- При первом запуске на 2.22 пользователи с активным DNS Helper
  увидят сообщение "previous installation, please reinstall" даже
  если фактически ничего не переустанавливали — потому что маркеры
  от ≤ 2.21 не содержали fingerprint. Это разовый клик на Reinstall;
  начиная со следующего запуска работает уже корректно.

## [2.21] — 2026-05-06

### Добавлено
- **Распознавание ошибки несоответствия имени хоста сертификату.**
  Добавлен новый case `TunnelError.serverCertificateNameMismatch`,
  срабатывающий на сообщения ngate вида `"The host name did not
  match any of the valid hosts for this certificate"` (и несколько
  смежных формулировок). Ошибка non-retryable — попытки
  переподключения не помогут, нужно либо администратору поправить
  TLS-сертификат шлюза, либо пользователю исправить URL. Popup
  показывается автоматически через стандартный `applyConnectionError`
  pipeline; текст: "The server's TLS certificate does not match this
  gateway's host name. The administrator needs to fix the certificate,
  or the URL is wrong."

## [2.20] — 2026-05-06

### Исправлено
- **Параллельные ошибки разных туннелей теперь все показываются.**
  Раньше если у двух туннелей одновременно возникала ошибка
  (например, проблемы с сертификатами), пользователь видел popup
  только для одного из них — второй alert тихо отбрасывался строкой
  `guard !isAlertPresented else { return }`. Сейчас в `AppState`
  работает очередь pending-alerts: если уже показывается какой-то
  alert, новые попадают в очередь, и после dismiss'а текущего
  показывается следующий с задержкой 200мс (даём AppKit разобрать
  предыдущее окно). Дедуп (чтобы один и тот же burst log-строк
  не давал несколько одинаковых popup'ов) переехал из AppDelegate
  в AppState и теперь работает per-`(tunnelID, title, message)` —
  ошибки разных туннелей не дедуплицируются вместе.

- **DNS Helper после переустановки приложения.** Раньше: если
  пользователь устанавливал DNS Helper, удалял .app bundle и
  ставил его заново (без uninstall'а helper'а сначала), новая
  установка приложения видела что helper script + sudoers entry
  всё ещё на диске и `Settings → DNS Helper` показывал "active",
  хотя по факту никакого route-cleanup'а или privilege'ов между
  старым helper'ом и новым приложением нет. Сейчас: каждая
  установка приложения генерирует UUID при первом запуске
  (хранится в UserDefaults), и этот UUID stamps в marker file
  при каждой записи. При запуске мы сверяем UUID из marker file
  с тем, что в UserDefaults — если разные, переходим в state
  `.error` с сообщением "DNS Helper was installed by a previous
  installation of this app. Please reinstall to reactivate." —
  пользователь видит что helper не активен и нужно переустановить.
  Маркеры от версий ≤ 2.19 без UUID мигрируют один раз при
  первом запуске на 2.20, после чего работает обычная проверка.

## [2.19] — 2026-05-06

### Исправлено
- **Краш приложения при открытии вкладки Журнал.** В 2.18 для попытки
  улучшить anchor-логику были добавлены вызовы
  `layoutManager.glyphRange(for: textContainer)`,
  `layoutManager.usedRect(for: textContainer)` и прямое присваивание
  `self.frame = newFrame` внутри `setFrameSize(_:)`. Все три
  внутренне переходят через AppKit'овский метод
  `_resizeTextViewForTextContainer`, который рекурсивно вызывает
  `setFrameSize` обратно. На любом первичном layout pass'е (например
  при первом открытии Журнала) это давало бесконечную рекурсию и
  крашило приложение со переполнением стека.

### Изменено
- **Откат 2.16–2.18 anchor-фиксов.** Возвращена простая логика без
  layout-trigger'ящих вызовов: `frame.height` вместо `usedRect`,
  отсутствие manual clamp'а в scroll path (NSClipView clamp'ит сам).
  Это означает что в самом низу лога при сужении anchor character
  может оказаться немного выше bottom edge — это известный trade-off:
  единственные альтернативы (`usedRect`, `glyphRange(for: container)`)
  recurse через AppKit. Полное исправление потребует переписывания
  на TextKit 2 (`NSTextLayoutManager`), что выходит за рамки точечного
  фикса. Anchor поведение в середине лога — корректное.

## [2.16] — 2026-05-06

### Исправлено
- **Anchor журнала наконец работает корректно при сужении окна.**
  Корень проблемы был не в выборе anchor character'а (это было
  исправлено в 2.15), а в **clamp-логике scroll'а**. Использовали
  `self.frame.height` как высоту документа — но `frame` устанавливается
  AppKit'ом из размера, переданного в `setFrameSize(_:)` (обычно это
  размер viewport'а, а не реальная высота text-документа после reflow).
  При сужении окна document height растёт (строки переносятся), но
  `frame.height` отражает только новый размер view'а внутри viewport'а
  — поэтому `clampedY = min(targetY, documentHeight - viewportHeight)`
  возвращал слишком маленькое значение, и character оставался ниже
  viewport'а. Сейчас используется `layoutManager.usedRect(for:)` —
  истинная высота нелайаутенного текста. Также теперь явно синхронизируем
  `self.frame.size.height` после reflow, чтобы scroll view не накручивал
  ошибку на следующем tick'е live resize'а.

## [2.15] — 2026-05-06

### Исправлено
- **Корректное поведение anchor'а в журнале при сужении окна.** В 2.14
  использовался `glyphRange(forBoundingRect:in:)` для определения
  последнего видимого character'а — но этот метод **исключает**
  line fragment'ы, которые видимы лишь частично у нижней границы
  viewport'а. Если последняя строка обрезалась нижним краем хотя бы
  на полпиксела, мы возвращали character на одну строку выше — и
  после reflow он действительно ехал выше последней видимой строки.
  Сейчас используется `glyphIndex(for: bottomRight, in:)` — точечный
  hit-test в правом нижнем углу viewport'а. Возвращает character
  однозначно: тот самый, который пользователь видит в правом нижнем
  углу. Дополнительно вызывается `ensureLayout(for:)` перед probe,
  чтобы layout был готов даже после burst'а новых строк от ngate.

### Изменено
- **Help переведён на русский** и убрана секция Keyboard shortcuts —
  она дублировала стандартные macOS shortcut'ы, которые уже видны
  рядом с пунктами меню.

## [2.14] — 2026-05-06

### Исправлено
- **Журнал теперь сохраняет последнюю видимую строку при изменении
  ширины окна.** Предыдущая попытка использовала
  `glyphIndex(for:in:)` с точкой в bottom-left viewport'а, который
  возвращал **первый** glyph нижней строки. Когда строка переносилась
  на две визуальные после reflow, мы анкорились на её начале — и
  пользовательская строка уплывала вниз. Сейчас используется
  `glyphRange(forBoundingRect:in:)`, который возвращает диапазон
  glyph'ов, полностью видимых в viewport'е; берём **последний** из
  диапазона как пользовательский anchor. Тот самый character
  гарантированно остаётся видимым у нижней границы после reflow.

- **Help menu наконец работает.** Все предыдущие попытки трогать
  `NSApp.mainMenu` напрямую (как в `applicationWillFinishLaunching`,
  так и в `didFinishLaunching` через `DispatchQueue.main.async`)
  затирались SwiftUI, который **владеет** main menu и продолжает им
  управлять в фоне. Теперь использую SwiftUI-native API:
  `Settings { ... }.commands { CommandGroup(replacing: .help) { ... } }`.
  Это говорит SwiftUI напрямую "Help group мы переопределяем", и она
  больше не пытается inject'ить туда системный "App Help" пункт.
  Пункт **Ngate2VPN Help** (⌘?) теперь надёжно показывает наш alert
  с описанием функций приложения.

## [2.13] — 2026-05-06

### Исправлено
- **Журнал теперь всегда заканчивается на последнем (новейшем) событии
  при изменении ширины окна.** Предыдущая попытка в 2.12 пыталась
  сохранить позицию пользователя через character-level anchor — это
  технически работало, но не отвечало пользовательскому ожиданию
  "видеть самое свежее событие". Теперь любое изменение ширины
  завершает scroll'ом в самый низ документа, после reflow.
- **Меню Help теперь показывает наш контент.** Предыдущая попытка
  установить меню в `applicationWillFinishLaunching` затиралась
  SwiftUI, который позже строит свой default menu. Теперь установка
  происходит в `applicationDidFinishLaunching` через `DispatchQueue.`
  `main.async` — после того как SwiftUI закончит свою настройку.
  Также убран `NSApp.helpMenu = …`: эта строка триггерила автоматическое
  добавление AppKit'ом пункта "App Help" с линком на несуществующую
  help book — что и давало системное "Help isn't available". Теперь
  мы заменяем содержимое существующего Help submenu без обозначения
  его как "официальной" help-цели.

## [2.12] — 2026-05-06

### Исправлено
- **Журнал теперь сохраняет читаемое место при изменении ширины окна.**
  Раньше при сужении окна (когда строки переносятся на больше визуальных
  строк) viewport оставался в том же Y-положении, и последняя видимая
  строка уплывала вниз за пределы экрана — пользователь видел контент,
  который был выше его viewport'а. Теперь: если пользователь смотрит
  не дно лога, мы захватываем character index у нижней границы viewport
  до reflow и после reflow прокручиваем так, чтобы тот же символ
  оказался у нижней границы. "Последнее видимое событие" остаётся
  привязкой при любом изменении ширины. Stick-to-bottom (когда
  пользователь следит за live tail) работает как раньше.

### Изменено
- **Build number `(1)` убран из About panel.** Мы никогда его отдельно
  не инкрементировали — это был визуальный шум. Теперь About показывает
  только версию.
- **Меню Help теперь содержит полезный пункт.** Раньше клик показывал
  системное "Help isn't available for Ngate2VPN" — попытки убрать меню
  целиком не работали на macOS Tahoe (AppKit re-injection). Сейчас
  пункт **Ngate2VPN Help** (⌘?) открывает сводку с описанием вкладок,
  горячими клавишами, путями к логам, и заметкой по приватности.

## [2.11 (1)] — 2026-05-06

### Исправлено
- **Журнал теперь всегда открывается на последних событиях.** Раньше
  при первом открытии вкладки Журнал, переключении профиля или смене
  фильтра viewport мог оказаться где угодно. Теперь любая полная
  пересборка списка (initial render, profile switch, filter change,
  Clear) автоматически проматывает в конец. При обычном append'е новых
  строк по-прежнему respect'ится позиция пользователя — если он
  поднялся читать историю, его не дёргает вниз.
- **Устранено мерцание журнала при изменении ширины окна на самом
  низу лога.** Stick-to-bottom во время live resize теперь делается
  **синхронно внутри** `WrappingLogTextView.setFrameSize` —
  одновременно с принудительным re-layout текста, в одном вызове.
  Раньше это была async подписка на `frameDidChangeNotification`
  через `Task { @MainActor }`, и между моментом обновления layout'а
  и срабатыванием observer'а проскакивал кадр с устаревшей scroll-
  позицией — отсюда мерцание. В середине лога эффект не проявлялся
  потому что `isNearBottom` возвращало false и observer ничего не
  делал.

## [2.10 (1)] — 2026-05-06

### Изменено
- **`FileLogger` переписан на `AsyncStream` с одним consumer task'ом.**
  Раньше каждая строка лога создавала новый `Task { await ... }`. При
  включённом `-vvvv` режиме ngate с несколькими активными туннелями
  это означало десятки тысяч короткоживущих Task'ов в минуту — каждый
  аллоцировал свой continuation frame, попадал в очередь cooperative
  pool, конкурировал за executor актора. Теперь у каждого FileLogger
  один long-running consumer Task, который в `for await` цикле
  вычитывает строки из stream и передаёт их в `LogWriterActor`.

### Преимущества
- **Гарантированный FIFO порядок.** Строки попадают на диск ровно в
  том порядке, в котором были вызваны `append()`. Раньше две Task'и,
  suspend'нувшиеся на одном await, могли resume'нуться не по порядку.
- **Меньше нагрузки на runtime scheduler.** Ноль аллокаций Task'ов на
  hot path — `continuation.yield()` это просто atomic enqueue.
- **Backpressure protection.** Stream имеет bounded buffer на 4 096
  строк с политикой `bufferingNewest` — если диск замедлится или
  ngate выдаст пиковый burst, старые строки отбрасываются вместо
  неограниченного роста памяти. В нормальной работе буфер пустой.
- **Чистый shutdown.** В `deinit` вызывается `continuation.finish()`,
  consumer Task завершается естественно, актор и handle освобождаются.

## [2.9 (1)] — 2026-05-06

### Изменено
- **Расширен in-memory буфер журнала.** Раньше каждое подключение
  хранило только последние 200 строк лога — при `-vvvv` режиме ngate
  это означало терять историю каждые несколько секунд. Лимит поднят
  до **30 000 строк на туннель** + **5 000 строк системных событий**
  (≈ 1–3 часа `-vvvv` вывода). Лимит безопасен потому что в 2.6 был
  внедрён инкрементальный рендеринг — добавление строки больше не O(N)
  по размеру журнала.
- **Amortised trimming.** Буфер трим'ится только когда переполняется
  на `slack` (1 000) элементов сверх лимита, а не на каждое
  превышение. Это превращает overhead с O(N) на каждый append в
  амортизированно константный.
- **Fast-path для отображения журнала с одним выбранным туннелем.**
  Когда юзер смотрит один туннель И System выключен, все entries
  идут из одного источника в правильном порядке — sort пропускается
  целиком, экономится ~N·log(N) сравнений на каждый render. На
  заполненном буфере 30 k строк это десятки миллисекунд.

### Контекст
- Старые строки остаются на диске через `FileLogger` (5 МБ ротация,
  30 дней хранения). UI журнала показывает только то что в RAM —
  ничего не потеряно, просто старое не отображается.
- Пять активных туннелей с заполненными буферами ≈ 15 МБ RAM, что
  соизмеримо с 1 кадром React-приложения.

## [2.8 (1)] — 2026-05-06

### Изменено
- **Архитектурная чистка `AppState`.** Из god-class'а на 1191 строку
  вынесены два логически отдельных модуля:
  - `NgateOutputParser` — pure parsing of ngate stdout: `classifyError`,
    `indicatesNgateReconnect`, `extractClientAddress`. Без зависимостей
    на UI / runtime / MainActor; легко тестируется изолированно.
  - `TunnelPersistence` + `PersistedState` — UserDefaults persistence,
    единая точка для load/save. Magic key `"ngate2vpn.saved.state"`
    больше не дублируется в двух местах.

  Поведение и публичный API `AppState` не изменились — это чисто
  механический refactor. Watchdog и lifecycle-логика **специально**
  оставлены в `AppState` потому что они плотно интегрированы с
  `@Published` runtime state — extract'ивный refactor усложнил бы код
  без пользы.

## [2.7 (1)] — 2026-05-06

### Безопасность
- **Credentials больше не передаются как command-line arguments.** Раньше
  пароли, PIN-коды и SHA1-отпечатки сертификатов были видны любому
  локальному пользователю системы через `ps aux`, попадали в
  `sysdiagnose`, crash reports и системные логи macOS — что нарушало
  обещание README "никогда не попадают в логи или открытое хранение".
  Теперь при запуске туннеля пишется временный INI-файл в
  `~/Library/Caches/Ngate2VPN/secure-configs/<uuid>.cfg` с правами
  `0600` (только текущий пользователь), и `ngateconsoleclient`
  получает его через флаг `-c <path>`. В `ps` теперь видна только
  команда `ngateconsoleclient -c /path/to/file.cfg -N -vvvv`.
  Файл удаляется в `terminationHandler` процесса, плюс на старте
  приложения подметаются "сироты" от прошлых крашей.

## [2.6 (1)] — 2026-05-06

### Изменено
- **Инкрементальный рендеринг журнала.** Раньше при каждом новом событии
  лога весь `NSAttributedString` пересобирался с нуля — становилось
  заметно при тысячах строк (`-vvvv` режим ngate). Теперь при добавлении
  новых строк строится и аппендится только их кусок, что превращает
  стоимость одного события из O(N) в O(K) (K — число новых строк).
  Полная пересборка остаётся для смены фильтров, выбора профиля и
  очистки журнала.
- **Watchdog: экспоненциальный backoff и circuit breaker.** Раньше после
  retryable ошибки watchdog перезапускал туннель раз в 5 секунд
  бесконечно — при многочасовом отказе шлюза журнал заполнялся сотнями
  одинаковых сообщений. Теперь задержка между попытками удваивается
  (5s, 10s, 20s, 40s, 80s, 160s, 320s, 640s, capped at 15 min), а после
  8 неудачных попыток подряд auto-reconnect ставится на паузу — туннель
  ждёт ручного действия пользователя. Успешное "vpn online" сбрасывает
  счётчик; ручной toggle снимает паузу и начинает с базовой задержки.

### Исправлено
- **Перенос строк журнала во время изменения размера окна.** Текст
  переноса теперь обновляется непрерывно на каждом пикселе ресайза.
  Раньше перенос "залипал" на старой ширине и последние слова дёргались
  на новую строку только в момент отпускания мыши. Причина —
  `NSLayoutManager` откладывает re-flow до конца live resize в целях
  производительности; фикс через subclass `NSTextView` с переопределением
  `setFrameSize(_:)`, принудительно вызывающим
  `textContainerChangedGeometry(_:)` на каждом изменении размера.

### Добавлено
- Состояние **System** pill на вкладке Журнал теперь сохраняется между
  запусками (`@AppStorage("journalShowSystem")`).

## [2.4 (1)] — 2026-05-06

### Добавлено
- Отображение выданного клиенту `ClientAddress` в строке профиля на
  главной вкладке после успешного подключения.
- Скрипт `Scripts/publish_github_release.sh` для публикации кода в
  приватный GitHub-репозиторий и загрузки собранного `.app` в GitHub
  Releases.

### Изменено
- Журнал теперь сортирует единый поток событий по времени.
- Системные события вынесены в отдельный app-wide буфер и больше не
  дублируются для каждого туннеля.
- UI журнала автоматически прокручивается к новым событиям.
- Строки логов с tab-отступами ngate отображаются стабильнее и не
  переносятся сразу после `Debug` только из-за tab stop.
- IP адрес подключённого профиля отображается справа как status badge.

### Исправлено
- Кнопки `Copy` и `Clear` в журнале больше не переносятся на две строки
  при минимальной ширине окна.
- `Connect All` больше не использует один общий startup-id для параллельных
  запусков туннелей.
- Watchdog снова стартует после добавления профиля в ранее пустой список.
- DNS Helper теперь строго отклоняет некорректные домены и IP вместо
  молчаливого удаления запрещённых символов.
- Пути staging-файлов в privileged install script корректно shell-экранируются.

## [2.3 (1)] — 2026-05-03

### Изменено
- **DNS Helper переписан с нуля.** Архитектура `SMAppService` daemon была
  отброшена: на macOS Sequoia / Tahoe `launchd` отвергает ad-hoc-подписанные
  daemon-binaries (`Bootstrap failed: 5`), а Apple Developer ID требует
  платного аккаунта. Новая модель использует одну `sudoers.d` запись с
  правилом `NOPASSWD` на конкретный helper-script — установка одним
  системным диалогом пароля, дальше всё silent.

### Добавлено
- **Один пароль для DNS Helper.** Запрос пароля администратора показывается
  только при первичной установке `Settings → DNS Helper → Install`.
  Все последующие подключения / отключения туннелей не дёргают пользователя.
- **Автоматическая чистка `/etc/resolver/` при выходе из приложения.**
  При `Cmd+Q`, выборе `Quit` в меню или закрытии окна (если включено
  «скрывать из Dock») приложение проходит через `applicationShould-`
  `Terminate` → `wipeAllRoutes()` → удаляет все split-DNS файлы которые
  создавало → только потом завершается. 3-секундный watchdog защищает от
  залипания на quit.
- **Восстановление после Force Quit / краша.** Состояние `writtenDomains`
  и `defaultInstalled` сохраняется в JSON marker-файле после каждой
  операции. При следующем запуске приложение знает какие файлы оно
  оставило в `/etc/resolver/` и может их корректно почистить через
  стандартный diff-механизм без всяких prompts.
- **Безопасная helper-программа.** Все входные данные валидируются и в
  Swift, и в bash через строгие regex (`^[a-z0-9.-]+$` для доменов,
  `^[0-9a-fA-F.:]+$` для IP). Запрещены `..`, лидирующая точка, длины
  больше 253/45 символов соответственно. `visudo -cf` валидирует
  `sudoers.d` запись перед установкой.
- **`UNINSTALL_SELF` команда в helper.** Helper сам удаляет свой
  `sudoers.d` файл и self-deletes — Uninstall в UI не требует пароля.

### Исправлено
- Проблема: при выходе из приложения с активными туннелями файлы в
  `/etc/resolver/` оставались — теперь корректно удаляются.
- Проблема: после Force Quit `/etc/resolver/` оставалась грязной —
  теперь автоматически очищается при следующем запуске приложения.
- Проблема: каждое подключение / отключение туннеля показывало диалог
  пароля — теперь один диалог при первоначальном Install.
- Удалены ошибки компиляции Swift 6: `ambiguous use of Task.init` и
  дубликат `appendBulkSystemLog`.

### Удалено
- `Sources/DNSHelper/` — daemon target (больше не нужен).
- `Sources/DNSHelperShared/` — XPC protocol target.
- `Resources/com.ngate2vpn.dnshelper.plist` — LaunchDaemon manifest.
- `import ServiceManagement` в `ContentView.swift` и `DNSApplier.swift`.
- Промежуточная попытка с Keychain-cached admin password — была
  заменена на `sudoers.d` подход с лучшим UX.

### Безопасность
- Sudoers entry разрешает запуск **ровно одного скрипта** этим
  пользователем. Все остальные `sudo` команды как и прежде требуют
  пароль.
- Helper script установлен как `root:wheel` mode `700` — другие
  пользователи не могут его модифицировать.
- Никаких паролей не хранится в Keychain — устранена точка отказа
  при смене системного пароля.

---

## [2.2 (1)] — 2026-04-30

### Добавлено
- Раздел Settings → DNS Helper для управления split-DNS.
- Toggle `Hold Default DNS` для контроля catch-all резолвера.
- Парсер JSON-ответа шлюза для извлечения DNSs / SearchDomains.
- Журнал событий DNS Helper в общем потоке `[SYSTEM]`.

### Изменено
- Версия в About panel обновлена до 2.2.
- Цветовая схема журнала и улучшенная фильтрация.

---

## [2.1 (1)] — ранее

### Добавлено
- Темы оформления: System / Light / Dark.
- Watchdog для авто-переподключения retryable ошибок.
- Расширенная классификация ошибок ngate-client.
- Многотуннельный режим с раздельными журналами.

---

## [2.0 (1)] — base

Первая публичная версия с базовым функционалом VPN-клиента
для нескольких туннелей одновременно.
