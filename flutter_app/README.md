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
| 0 | Foreground service + wake locks, bundled cloudflared, test server, self health checks, Debug screen | in progress |
| 1 | Port the attendance server to Dart (parity with the Python scenario tests), save to disk as it goes | |
| 2 | Setup / dashboard / QR / End session screens, CSV share | |
| 3 | Crash recovery, tunnel auto-restart, battery-optimisation guidance | |
| 4 | Real classroom test | |

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
