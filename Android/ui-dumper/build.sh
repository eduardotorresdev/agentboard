#!/bin/sh
# Builds Sources/AgentBoard/Resources/ui-dumper.dex from UiDumper.java: javac (17+) against the
# newest android.jar of the SDK, then d8 from its newest build-tools. Only needed after changing
# the Java; the app ships the checked-in dex and never needs the SDK to build.
set -eu
cd "$(dirname "$0")"
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
JAR="$(ls -d "$SDK"/platforms/android-* | sort -V | tail -n 1)/android.jar"
D8="$(ls -d "$SDK"/build-tools/* | sort -V | tail -n 1)/d8"
OUT="$(mktemp -d)"
javac --release 11 -cp "$JAR" -d "$OUT" UiDumper.java
"$D8" --min-api 26 --lib "$JAR" --output "$OUT" "$OUT"/agentboard/*.class
cp "$OUT/classes.dex" ../../Sources/AgentBoard/Resources/ui-dumper.dex
rm -rf "$OUT"
