#!/bin/sh
# Installs minis-hostd for the current user. Run on the host:
#   curl -fsSL <url>/install.sh | sh -s -- --host-name <name> --version <version>
#   curl -fsSL <url>/install.sh | sh -s -- --pair --version <version>
# It downloads the release binary for this OS and CPU, checks its SHA-256 and installs it to
# ~/.minis/bin/minis-hostd. With --host-name it then writes ~/.minis/hostd/config.toml if there is
# none yet and prints the steps to start the push service; with --pair it runs
# `minis-hostd pair` instead, which shows the code to scan in Minis.
set -eu

repo_releases="https://github.com/NoSugarCoffee/Pico/releases/download"

fail() {
	echo "minis-hostd install: $*" >&2
	exit 1
}

usage() {
	echo "usage: sh install.sh (--host-name <name> | --pair) --version <version> [--base-url <url>]" >&2
	echo "  --pair      install the binary only, then pair this computer with Minis" >&2
	echo "  --base-url  download from <url>/<asset> instead of the GitHub release (mirrors, testing)" >&2
	exit 64
}

host_name=""
pair=0
version=""
base_url=""
while [ "$#" -gt 0 ]; do
	case $1 in
	--host-name)
		[ "$#" -ge 2 ] || usage
		host_name=$2
		shift 2
		;;
	--pair)
		pair=1
		shift
		;;
	--version)
		[ "$#" -ge 2 ] || usage
		version=$2
		shift 2
		;;
	--base-url)
		[ "$#" -ge 2 ] || usage
		base_url=$2
		shift 2
		;;
	*) usage ;;
	esac
done
if [ "$pair" = 1 ]; then
	[ -z "$host_name" ] || usage
else
	[ -n "$host_name" ] || usage
fi
[ -n "$version" ] || usage
version=${version#v}
[ -n "$base_url" ] || base_url="$repo_releases/hostd-v$version"

[ -n "${HOME:-}" ] || fail "HOME is not set"

case $(uname -s) in
Darwin) os=darwin ;;
Linux) os=linux ;;
*) fail "unsupported OS '$(uname -s)'; minis-hostd runs on macOS and Linux" ;;
esac
case $(uname -m) in
arm64 | aarch64) arch=arm64 ;;
x86_64 | amd64) arch=amd64 ;;
*) fail "unsupported CPU '$(uname -m)'; minis-hostd runs on arm64 and amd64" ;;
esac

if command -v sha256sum >/dev/null 2>&1; then
	sha256() { sha256sum "$1" | cut -d ' ' -f 1; }
elif command -v shasum >/dev/null 2>&1; then
	sha256() { shasum -a 256 "$1" | cut -d ' ' -f 1; }
else
	fail "neither sha256sum nor shasum found, so the download cannot be verified"
fi
command -v curl >/dev/null 2>&1 || fail "curl not found"

asset="minis-hostd-$version-$os-$arch"
bin_dir="$HOME/.minis/bin"
binary="$bin_dir/minis-hostd"
config="$HOME/.minis/hostd/config.toml"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

echo "Downloading $asset" >&2
curl -fsSL -o "$work/$asset" "$base_url/$asset" || fail "could not download $base_url/$asset"
curl -fsSL -o "$work/SHA256SUMS" "$base_url/SHA256SUMS" || fail "could not download $base_url/SHA256SUMS"

expected=$(awk -v f="$asset" '$2 == f || $2 == "*" f { print $1 }' "$work/SHA256SUMS")
[ -n "$expected" ] || fail "SHA256SUMS has no entry for $asset"
actual=$(sha256 "$work/$asset")
[ "$actual" = "$expected" ] || fail "checksum mismatch for $asset: expected $expected, got $actual. The download is corrupt or was tampered with; nothing was installed."

mkdir -p "$bin_dir"
chmod 0755 "$work/$asset"
# Same-directory rename replaces a running binary without "text file busy" and never leaves a
# half-written file at the final path.
cp "$work/$asset" "$binary.new"
mv -f "$binary.new" "$binary"
echo "Installed $binary ($("$binary" version --json))" >&2

if [ "$pair" = 1 ]; then
	exec "$binary" pair
fi

if [ -e "$config" ]; then
	echo "Keeping existing $config" >&2
else
	"$binary" new-config --host-name "$host_name"
fi

# The service is not started here: with the template's placeholders the daemon would exit and be
# restarted every few seconds. install-service refuses until the config loads.
cat >&2 <<EOF

Next steps:
  1. Edit $config: turn on a Gmail account or GitHub, and paste the Bark device key.
     In the Bark app, set Push Encryption to AES256 / GCM / noPadding with the encryption_key
     from the file.
  2. Check everything and send a test push:
       $binary doctor --push-test
  3. Start it as a service:
       $binary install-service
EOF
