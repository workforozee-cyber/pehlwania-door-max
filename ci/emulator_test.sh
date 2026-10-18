#!/usr/bin/env bash
# Runs inside reactivecircus/android-emulator-runner (emulator already booted).
set -u
PKG=com.pehlwania.doormax
adb wait-for-device
adb shell settings put global window_animation_scale 0 || true
adb logcat -c || true

echo "== 1. CI test build (WebView debugging enabled) =="
date; adb devices; adb shell getprop ro.build.version.release
adb install -r ci-apk/app-debug.apk || { echo "FAIL install of CI test APK"; }
(cd web-tests && timeout 1500 node android_e2e.mjs > ../e2e-output.log 2>&1); E2E=$?
cat e2e-output.log | tail -300
echo "android_e2e exit=$E2E"; date
adb logcat -d -t 400 > emulator-logcat-e2e.txt

echo "== 2. Shop release APK: install, launch, check it stays up =="
adb uninstall "$PKG" || true          # different signing key than the CI test build
REL=$(ls rel-apk/PehlwaniaPOS-*.apk | head -1)
adb install "$REL"; INST=$?
adb shell am start -W -n "$PKG/com.pehlwania.pehlwania_pos.MainActivity"
sleep 20
PID=$(adb shell pidof "$PKG" | tr -d '\r')
if [ -z "$PID" ]; then
  # the emulator sometimes kills apps when Google Play services restarts; launch once more
  adb logcat -d | grep -i "Killing.*$PKG" | tail -2
  adb shell am start -W -n "$PKG/com.pehlwania.pehlwania_pos.MainActivity"; sleep 20
  PID=$(adb shell pidof "$PKG" | tr -d '\r')
fi
mkdir -p web-tests/android-shots
adb exec-out screencap -p > web-tests/android-shots/10-release-apk-running.png
adb logcat -d > emulator-logcat.txt
if [ "$INST" -eq 0 ] && [ -n "$PID" ] && ! adb logcat -d -b crash | grep -q "$PKG"; then
  echo "PASS  release APK installs, launches and keeps running (pid $PID)"; REL_OK=0
else
  echo "FAIL  release APK install=$INST pid='$PID'"; adb logcat -d -b crash | tail -50; REL_OK=1
fi
exit $(( E2E || REL_OK ))
