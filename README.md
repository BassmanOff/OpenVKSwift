# OpenVK iOS

Нативный iOS-клиент для [OpenVK](https://openvk.github.io/docs/) в стилистике старого ВКонтакте.
Минимальная версия — **iOS 15**. Цель — повторить дизайн VK 2014–2016 / клиента OpenVK Legacy.

## Статус

Фаза 1 (фундамент) — в работе:

- [x] Сетевой слой (VK-совместимый API OpenVK)
- [x] Авторизация по логину/паролю (`/token`, поддержка 2FA)
- [x] Выбор инстанса (`openvk.org` HTTPS / `openvk.xyz` HTTP)
- [x] Хранение токена в Keychain
- [x] Дизайн-система (цвета VK)
- [x] Музыка: плеер с фоновым воспроизведением, локскрин-контролы, **офлайн-загрузки**
- [ ] Лента, профиль, друзья, сообщения — дальше

## Как собрать (на macOS / Hackintosh)

Проект описан текстом в `project.yml` и генерируется через **XcodeGen**, чтобы его можно было
вести с Windows без правки бинарного `.xcodeproj`.

```bash
# 1. Установить XcodeGen (один раз)
brew install xcodegen

# 2. Сгенерировать Xcode-проект из project.yml
cd OVK_iOS
xcodegen generate

# 3. Открыть
open OVK.xcodeproj
```

В Xcode:

1. Выбери таргет **OVK** → вкладка **Signing & Capabilities**.
2. Поставь галку **Automatically manage signing** и выбери свой **Team** (бесплатный Apple ID подойдёт).
3. При необходимости поменяй **Bundle Identifier** на уникальный (напр. `com.<твоёимя>.ovk`).
4. Подключи iPhone по USB, выбери его как устройство и нажми **Run** (⌘R).
5. На iPhone: **Настройки → Основные → VPN и управление устройством** → доверять профилю разработчика.

> Бесплатная подпись действует **7 дней** — после этого просто пересобери из Xcode.
> Платный Apple Developer ($99/год) снимает это ограничение и открывает TestFlight.

## Заметки

- **HTTP-инстансы.** `openvk.xyz` работает только по HTTP, поэтому в `Info.plist` включён
  `NSAllowsArbitraryLoads`. Дефолтный инстанс — `openvk.org` (HTTPS).
- **Музыка.** Включён фоновый режим `audio`; загруженные треки лежат в Application Support и
  играют офлайн.

## Структура

```
Sources/
  App/            — точка входа, корневой роутинг
  Core/
    Networking/   — OVKClient (VK-совместимые вызовы), ошибки
    Auth/         — получение токена, Keychain
    Settings/     — выбор инстанса, состояние сессии
  Models/         — User, Audio, ...
  DesignSystem/   — цвета/темы в стиле VK
  Features/
    Auth/         — экран входа
    Audio/        — плеер, загрузки, список музыки
    Main/         — таб-бар
Support/
  Info.plist      — генерируется XcodeGen-ом
```
