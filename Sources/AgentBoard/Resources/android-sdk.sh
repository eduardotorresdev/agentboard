#!/bin/sh
# Installs what an Android emulator card needs into $HOME/.agentboard/android-sdk: the
# command-line tools, platform tools, the emulator and one system image, accepting their
# licenses. Java 17+ is downloaded next to them when the machine has none. Runs on macOS and
# Linux; the board runs it detached and reads its log: "progress=" lines, sdkmanager's
# percentages, and "done" at the end.
set -eu
SDK="$HOME/.agentboard/android-sdk"
API="${API:-35}"
case "$(uname -s)" in Darwin) os=mac ;; Linux) os=linux ;; *) echo "This system can't run the Android emulator." >&2; exit 1 ;; esac
case "$(uname -m)" in x86_64 | amd64) abi=x86_64 ;; *) abi=arm64-v8a ;; esac
if [ "$os" = linux ] && [ "$abi" = arm64-v8a ]; then echo "The Android emulator doesn't run on Linux on ARM." >&2; exit 1; fi
mkdir -p "$SDK"
cd "$SDK"

fetch() { if command -v curl >/dev/null 2>&1; then curl -fsSL "$1" -o "$2"; else wget -q "$1" -O "$2"; fi; }
java_ok() { "$1" -version 2>&1 | awk -F'"' '/version/ { split($2, v, "."); found = 1; exit !(v[1] >= 17) } END { if (!found) exit 1 }'; }

JAVA=""
for candidate in "${JAVA_HOME:-/nonexistent}/bin/java" "$SDK/jdk/bin/java" "$SDK/jdk/Contents/Home/bin/java" "$(command -v java || true)"; do
  if [ -x "$candidate" ] && java_ok "$candidate"; then JAVA="$candidate"; break; fi
done
if [ -z "$JAVA" ]; then
  echo "progress=Downloading Java"
  if [ "$abi" = x86_64 ]; then arch=x64; else arch=aarch64; fi
  fetch "https://api.adoptium.net/v3/binary/latest/17/ga/$os/$arch/jre/hotspot/normal/eclipse" jre.tar.gz
  rm -rf jdk && mkdir jdk && tar -xzf jre.tar.gz -C jdk --strip-components=1 && rm jre.tar.gz
  JAVA="$SDK/jdk/bin/java"
  [ -x "$JAVA" ] || JAVA="$SDK/jdk/Contents/Home/bin/java"
fi
JAVA_HOME="$(dirname "$(dirname "$JAVA")")"
export JAVA_HOME

if [ ! -x cmdline-tools/latest/bin/sdkmanager ]; then
  echo "progress=Downloading the Android command-line tools"
  name="$(fetch https://dl.google.com/android/repository/repository2-3.xml - | grep -o "commandlinetools-$os-[0-9]*_latest.zip" | sort -u | tail -n 1)"
  [ -n "$name" ] || { echo "Couldn't find the Android command-line tools to download." >&2; exit 1; }
  fetch "https://dl.google.com/android/repository/$name" tools.zip
  rm -rf cmdline-tools && mkdir -p cmdline-tools
  if command -v unzip >/dev/null 2>&1; then unzip -q tools.zip -d cmdline-tools; else (cd cmdline-tools && jar xf ../tools.zip 2>/dev/null) || python3 -m zipfile -e tools.zip cmdline-tools; fi
  mv cmdline-tools/cmdline-tools cmdline-tools/latest
  chmod +x cmdline-tools/latest/bin/*
  rm tools.zip
fi

yes | cmdline-tools/latest/bin/sdkmanager --sdk_root="$SDK" --licenses >/dev/null 2>&1 || true
echo "progress=Installing the emulator and Android $API"
cmdline-tools/latest/bin/sdkmanager --sdk_root="$SDK" "platform-tools" "emulator" "system-images;android-$API;google_apis;$abi"
echo done
