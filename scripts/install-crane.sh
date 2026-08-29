#!/bin/sh

set -eu

version="0.21.7"
base_url="https://github.com/google/go-containerregistry/releases/download/v${version}"

case "$(uname -s):$(uname -m)" in
  Linux:x86_64)
    archive="go-containerregistry_Linux_x86_64.tar.gz"
    expected="1a57bc98207fa1c0d04bf760699099e26f8383499bfd55b99c1b919a928a7230"
    ;;
  Linux:aarch64|Linux:arm64)
    archive="go-containerregistry_Linux_arm64.tar.gz"
    expected="b6ee979d9411dfb05ce35ab9e156fe5de7def11a230764a7856ffa2eb971fa88"
    ;;
  *)
    printf 'error: no pinned crane archive for %s/%s\n' "$(uname -s)" "$(uname -m)" >&2
    exit 1
    ;;
esac

destination=${1:-"$HOME/.local/bin"}
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT HUP INT TERM

curl --fail --location --silent --show-error "$base_url/$archive" --output "$temporary/$archive"
printf '%s  %s\n' "$expected" "$temporary/$archive" | sha256sum --check --status
tar -xzf "$temporary/$archive" -C "$temporary" crane
mkdir -p "$destination"
install -m 0755 "$temporary/crane" "$destination/crane"
printf 'Installed crane %s to %s/crane\n' "$version" "$destination"

