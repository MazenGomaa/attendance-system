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
| 2 | Native dashboard (Overview / Students / Log tabs, export & share, reset for a new take, new subject), class-list import, local-network (Wi-Fi/hotspot) mode, remembered settings | done, testing on phone |
| 3 | Crash recovery, tunnel auto-restart, battery-optimisation guidance | |
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
  optional web-dashboard password, local-network mode, 0-4 tunnels.
- **Local-network mode** listens on the phone's Wi-Fi/hotspot address too
  (`http://<phone-ip>:8000`, shown with a QR). With 0 tunnels it works
  without internet: turn on the hotspot and have students join it.
  "Allow the web dashboard from the same network" lets a laptop on that
  network open `/admin` (set a password on shared networks).
- **While running**: Overview (counts, links, QR), Students (searchable, with
  distance and flags), Log (edits and refused ID conflicts). The ⋮ menu has
  Export & share now, Reset for a new take, and New subject (saves the
  current one to `Download/Attendance` and starts the next with the same
  links).

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
