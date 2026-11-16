#!/bin/sh
# Installs the agentboard host program for this user, without root. See docs/hosts.md.
set -eu

# In a function, called on the last line: a download cut short runs nothing.
main() {
  base="${AGENTBOARD_DOWNLOAD:-https://agentboard-account.agentboard-account-server.workers.dev/download}"
  case "$base" in
    https://*) ;;
    *) fail "the download address must be https" ;;
  esac
  [ "$(uname -s)" = Linux ] || fail "hosts are Linux-only for now"
  case "$(uname -m)" in
    x86_64 | amd64) arch=x86_64 ;;
    aarch64 | arm64) arch=aarch64 ;;
    *) fail "unsupported architecture: $(uname -m)" ;;
  esac

  name="agentboard-linux-$arch"
  bin="$HOME/.local/bin"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  fetch "$base/$name" "$tmp/$name"
  fetch "$base/$name.sha256" "$tmp/$name.sha256"
  want="$(cut -d' ' -f1 "$tmp/$name.sha256")"
  got="$(sha256sum "$tmp/$name" | cut -d' ' -f1)"
  [ -n "$want" ] && [ "$want" = "$got" ] || fail "the download does not match its checksum"

  mkdir -p "$bin"
  chmod 755 "$tmp/$name"
  mv "$tmp/$name" "$bin/agentboard"

  echo "Installed $bin/agentboard"
  case ":$PATH:" in
    *":$bin:"*) echo "Next: agentboard login" ;;
    *) echo "Next: $bin/agentboard login" ;;
  esac
}

fail() {
  echo "error: $1" >&2
  exit 1
}

fetch() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 -o "$2" "$1" || fail "could not download $1"
  elif command -v wget >/dev/null 2>&1; then
    wget -q --https-only -O "$2" "$1" || fail "could not download $1"
  else
    fail "curl or wget is needed"
  fi
}

main
