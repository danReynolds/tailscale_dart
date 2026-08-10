#!/usr/bin/env bash
set -euo pipefail

adb logcat -c
adb install -r /tmp/smoke/build/app/outputs/flutter-apk/app-debug.apk
adb shell am start -n com.example.smoke/.MainActivity

# The issue #81 crash was immediate, on the reactor's first poll.
sleep 25

echo "--- confirming the process is still alive ---"
APP_PID="$(adb shell pidof com.example.smoke 2>/dev/null | tr -d '\r' || true)"
if [[ -z "$APP_PID" ]]; then
  adb logcat -d > /tmp/logcat.txt || true
  echo "FAIL: app process is not running after launch."
  tail -200 /tmp/logcat.txt
  exit 1
fi

# Restrict the positive-path SIGSYS check to this app. Device-wide logcat can
# contain unrelated seccomp failures from emulator services and should not make
# this receipt flaky.
adb logcat -d --pid="$APP_PID" > /tmp/logcat.txt || true
echo "--- confirming Tailscale.init completed ---"
if ! grep -Fq 'TAILSCALE_DART_SMOKE_READY' /tmp/logcat.txt; then
  echo "FAIL: app process survived, but Tailscale.init did not report completion."
  tail -200 /tmp/logcat.txt
  exit 1
fi

echo "--- searching the app log for seccomp kills ---"
if grep -Eq 'SIGSYS|SYS_SECCOMP|seccomp prevented' /tmp/logcat.txt; then
  echo "FAIL: seccomp killed the process; issue #81 has regressed."
  grep -E -B5 -A20 'SIGSYS|SYS_SECCOMP|seccomp prevented' /tmp/logcat.txt || true
  exit 1
fi

echo "PASS: app survived startup on Android x86_64."
