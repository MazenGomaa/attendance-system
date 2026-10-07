# Attendance Host (Flutter, Android)

Runs the attendance server and Cloudflare Quick Tunnels on the professor's
Android phone. Work in progress, see the phases below. The Python version in
the repo root stays maintained alongside it.

## Builds

Every push touching `flutter_app/`, `static/` or the workflow runs
`.github/workflows/android-apk.yml`, which:

1. builds `cloudflared` from Cloudflare's source for `android/arm64` with cgo
   (Android's DNS resolver; the generic Linux build can't resolve on Android),
2. bundles it as `jniLibs/arm64-v8a/libcloudflared.so` (extracted to
   `nativeLibraryDir`, the one place Android lets an app execute its own binary),
3. builds a release APK and publishes it as a pre-release `app-build-<n>`
   (latest 5 kept). Download the `.apk` from the repo's Releases page on the phone.

All builds are signed with `android/app/dev-signing.keystore` so each one
installs over the previous one. It's a development key for a private repo;
move signing to CI secrets before distributing more widely.

## Phases

| Phase | Scope | Status |
|---|---|---|
| 0 | Foreground service + wake locks, bundled cloudflared, test server, self health checks, Debug screen | done |
| 1 | Port the attendance server to Dart (parity with the Python scenario tests), save to disk as it goes | done |
| 2 | Native dashboard (Overview / Students / Log tabs, export & share, reset for a new take, new subject), class-list import, remembered settings | done |
| 3 | Link-changed alerts, restarting unreachable tunnels, background-settings guide per phone brand, pre-class check, resume warning | done, testing on phone |
| 4 | Real classroom test | |

## Server

`lib/server/` is a port of `app.py` in pure `dart:io` (`server.dart`, `model.dart`,
`exporter.dart`, `logic.dart`): same endpoints, messages, identity rules,
security checks and CSV files. `tests/parity.sh` (repo root) runs the HTTP
scenario suite against both servers and diffs their CSV exports; CI runs it.
`bin/serve.dart` starts the Dart server standalone for those tests.

Every state change is appended to a journal (`files/sessions/*.jsonl`). If the
app is killed mid-session, the start screen offers **Resume it** (rebuilds the
session from the journal) or **End it & save CSVs**.

## Using the app

- **Setup** (remembered between sessions, except the password): course name,
  location audit + radius, class list (CSV/TXT, IDs in the first column),
  optional web-dashboard password, 1-4 tunnels.
- Students always come in through the tunnels (HTTPS): browsers only allow
  location on HTTPS pages, so a plain-HTTP local Wi-Fi/hotspot link can't
  do the GPS audit (local-network mode was tried and removed).
- **While running**: Overview (counts, links, QR), Students (searchable, with
  distance and flags), Log (edits and refused ID conflicts). The ⋮ menu has
  Export & share now, Reset for a new take, and New subject (saves the
  current one to `Download/Attendance` and starts the next with the same
  links).

## Reliability

- **Tunnel links change when a tunnel restarts** (Quick Tunnels get a new
  random hostname each time). `TunnelManager` remembers the link the
  professor shared; if a restart produces a different one it raises a
  heads-up notification and a red in-app banner ("Share new QR" / "Done,
  I've shared it") until acknowledged. A resumed session always shows it.
- Tunnels are health-checked every 30 s. The app follows cloudflared's own
  connection state ("Registered" / "Connection terminated"). During a network
  outage it waits (offline: a restart can't help); once the phone is back
  online cloudflared gets 30 s to reconnect by itself, which keeps the same
  link, before it's killed and restarted (new link + alert). A connected
  tunnel whose public link fails 3 checks in a row is restarted too.
  Restarts never give up while a session runs (5 quick retries, then one a
  minute). Fresh-link checks resolve via Cloudflare DNS-over-HTTPS, and a
  phone-side DNS failure never counts toward a restart.
- **Background settings** (setup screen): battery-optimisation and
  notification status, plus brand-specific steps (Samsung, Xiaomi, OPPO /
  realme / OnePlus, vivo, Huawei / Honor) with a button that opens the
  maker's own screen, falling back to the app info page.
- **Pre-class check** (setup screen): checks cloudflared, battery and
  notifications, then opens a throwaway tunnel, loads the student page
  through it and records a test submission, and discards everything.

## How the app stays alive

`AttendanceApp` (the Android `Application`) creates the Flutter engine and
caches it; `MainActivity` only attaches to it. Swiping the app away destroys
the activity but not the engine, and `HostService` (a foreground service with
wake/Wi-Fi locks) keeps the process alive, so the session keeps running. Only
the in-app **Stop session** button ends it.

## Debugging

The bug icon opens the Debug screen: device info, battery-optimisation state,
`cloudflared --version`, and the last 500 log lines. **Copy all** puts a full
report on the clipboard.
