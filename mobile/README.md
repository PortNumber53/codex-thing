# Codex Local mobile client

This Flutter application is a native client for the Go bridge in the repository
root. It connects to the same REST, SSE, and WebSocket endpoints as the React Web
UI, so browser, terminal, and mobile clients share live Codex sessions.

## Mobile interaction model

- Each recent session across all workspaces is a full-screen horizontal page.
  Active sessions appear first; swipe left or right to change sessions without
  returning to a session list.
- The message composer is a fixed Android safe-area surface. It stays in place
  while session pages move behind it and changes to an interrupt button while
  the selected session is working.
- The session button in the upper-left opens a conventional session picker for
  direct navigation. Active sessions are marked with a bolt.
- New conversations support server-backed workspace path completion.
- Messages, command output, interruptions, approvals, model questions, active
  turns, and device authentication use the same live protocol as the Web UI.

## Run against a development server

Start the Go bridge from the repository root:

```bash
npm run dev:server
```

The Android emulator reaches the host through `10.0.2.2`, which is the default:

```bash
cd mobile
flutter pub get
flutter run
```

For a physical device, use a hostname or IP address that the device can reach:

```bash
flutter run --dart-define=CODEX_SERVER_URL=http://SERVER:40001
```

The server address can also be changed inside the app with the tune icon. The
selection is persisted on the device. Both `http://` and `https://` endpoints are
supported by the client; Android cleartext traffic is enabled because a one-host
LAN or VPN installation commonly serves the bridge over HTTP. Use HTTPS for an
iOS release unless its App Transport Security policy is configured separately.

The Go bridge has no application-level authentication. Only connect the mobile
app over a trusted LAN/VPN, or put an authenticated HTTPS reverse proxy in front
of port `40001`.

## Verification and release build

```bash
flutter analyze
flutter test
flutter build apk --release \
  --dart-define=CODEX_SERVER_URL=https://YOUR-CODEX-HOST
```
