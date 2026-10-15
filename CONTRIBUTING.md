# Contributing to Mailmule

Thanks for helping! Mailmule is a small project, so a short note before a big change saves everyone time:
open an issue describing what you would like to do, then send a pull request.

## Getting started

1. Build the app as described in the [README](README.md#building).
2. Run the core tests: `cd Packages/MailmuleKit && swift test`. They need no network or mail account.
3. Use a test mail account while developing. Mailmule really archives, deletes and sends mail.

## Where things live

- Protocols, parsing, storage and sync are in `Packages/MailmuleKit`. Logic belongs there whenever possible,
  with a test in `Tests/MailmuleKitTests`.
- The SwiftUI app is in `App/Sources`. `AppModel` holds app state; views live in `App/Sources/Views`.
- After adding or removing files, run `xcodegen generate`. The Xcode project is generated from `project.yml`.

## Style

- Swift 6 with strict concurrency. Network and storage work runs in actors (`AccountService`, `MailIndex`,
  `IMAPClient`), and UI state stays on the main actor.
- Match the surrounding code: its naming, its comment density, and its doc comments that say *why*.
- Keep pull requests focused: one feature or fix per PR, and no unrelated reformatting.
- New behaviour in the core comes with a test.

## Screenshots and demo data

`./scripts/demo.sh [home|inbox|thread|compose|search|settings]` starts a copy of the app with made-up
accounts and mail and no server connections. The copy has its own settings and a temporary mail folder,
so your real setup is never touched. Pass defaults to try a theme, for example
`./scripts/demo.sh thread -theme.preset everforest -theme.appearance dark`. Stop it with
`./scripts/demo.sh --stop`. The demo content is in `App/Sources/DemoMode.swift`.

Mail is drawn by WebKit only while the window is visible, so bring the demo window to the front before
taking a screenshot.

## Localization

The interface is currently Slovak only, and strings are written inline in the views. Help moving them to
String Catalogs (`Localizable.xcstrings`) and adding English or other languages is very welcome. Please open
an issue first so the work can be split up.

## Privacy and security

- Never commit real mail, addresses, passwords or tokens. Tests use made-up data (`example.com`).
- Mailmule must not send data anywhere except the user's own mail servers. The opt-in model download from
  Hugging Face and company logos for senders, which can be switched off, are the only exceptions.
  Don't add analytics or other network calls.
- Report security problems privately, as described in [SECURITY.md](SECURITY.md), not in public issues.

## License

By contributing you agree that your contributions are licensed under the
[GNU General Public License v3.0](LICENSE), the same license as the project.
