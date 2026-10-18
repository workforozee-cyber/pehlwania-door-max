#!/usr/bin/env bash
# Runs inside reactivecircus/android-emulator-runner (emulator already booted).
set -u
PKG=com.pehlwania.doormax
adb wait-for-device
adb shell settings put global window_animation_scale 0 || true
adb logcat -c || true

echo "== 1. CI test build (WebView debugging enabled) =="
adb install -r ci-apk/app-debug.apk
(cd web-tests && node android_e2e.mjs); E2E=$?

echo "== 2. Shop release APK: install, launch, check it stays up =="
adb uninstall "$PKG" || true          # different signing key than the CI test build
REL=$(ls rel-apk/PehlwaniaPOS-*.apk | head -1)
adb install "$REL"; INST=$?
adb shell am start -W -n "$PKG/com.pehlwania.pehlwania_pos.MainActivity"
sleep 20
PID=$(adb shell pidof "$PKG" | tr -d '\r')
mkdir -p web-tests/android-shots
adb exec-out screencap -p > web-tests/android-shots/10-release-apk-running.png
adb logcat -d > emulator-logcat.txt
if [ "$INST" -eq 0 ] && [ -n "$PID" ] && ! adb logcat -d -b crash | grep -q "$PKG"; then
  echo "PASS  release APK installs, launches and keeps running (pid $PID)"; REL_OK=0
else
  echo "FAIL  release APK install=$INST pid='$PID'"; adb logcat -d -b crash | tail -50; REL_OK=1
fi
exit $(( E2E || REL_OK ))
