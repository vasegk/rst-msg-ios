# RST Messenger для iOS

Нативный клиент RST на SwiftUI (iOS 17+). Повторяет протокол и схему сквозного
шифрования веб-клиента и Android-приложения: переписка читается одинаково на всех
трёх платформах.

Источник правды о протоколе — `PROMPT_ANDROID.md` в репозитории `rst-msg`
(он общий для мобильных клиентов). Опись возможностей — `PARITY.md` там же;
статус iOS по её номерам — [docs/PARITY_STATUS.md](docs/PARITY_STATUS.md).

## Сборка

Проект Xcode генерируется из [project.yml](project.yml) утилитой
[XcodeGen](https://github.com/yonaskolb/XcodeGen) — сам `.xcodeproj` в репозиторий
не кладётся.

**Без Mac — через GitHub Actions.** Каждый push в `main` запускает
[.github/workflows/ios.yml](.github/workflows/ios.yml) на macOS-раннере:

1. тесты криптографии и протокола на симуляторе;
2. сборка для устройства без подписи → артефакт `rst-ios-unsigned-ipa`.

Неподписанный `.ipa` можно поставить на свой iPhone через
[Sideloadly](https://sideloadly.io/) или AltStore с бесплатным Apple ID
(подпись на 7 дней). Для TestFlight и push-уведомлений нужен платный
Apple Developer аккаунт.

**На Mac:**

```bash
brew install xcodegen
xcodegen generate
open RST.xcodeproj
```

Адрес сервера — ключи `RSTBaseURL` и `RSTWebSocketURL` в [RST/Info.plist](RST/Info.plist).

## Устройство

```
RST/
├── App/            точка входа, AppModel (вход/выход, ссылки), контейнер сервисов
├── Core/Crypto     PBKDF2, AES-GCM, ECDH P-256 + JWK, конверт, ключи групп,
│                   вложения, ключ восстановления, код безопасности
├── Core/Net        REST (URLSession), WebSocket (токен в субпротоколе), модели
├── Core/Storage    связка ключей: токен, KEK, приватный JWK
├── Core/Text       разметка сообщений (**жирный**, ||спойлер||, ссылки…)
├── Data            ключи собеседников и групп, переписка, вложения, список чатов
└── UI              SwiftUI: вход, чаты, переписка, группы, профиль, настройки
RSTTests/           эталоны WebCrypto, контракты API, разметка
```

Криптография — только системные CryptoKit и CommonCrypto, сторонних зависимостей нет.

## Совместимость шифрования

`RSTTests/CryptoCompatibilityTests.swift` проверяет приложение на эталонах,
полученных настоящим WebCrypto (`crypto.subtle` в Node.js — та же реализация API,
что в браузере): ключ ECDH, расшифровка сообщения и конверта вложения из браузера,
приватный ключ, зашифрованный при регистрации в вебе, PBKDF2 на 100 000 и
600 000 итераций. Упал тест — приложение перестало понимать переписку из браузера.
