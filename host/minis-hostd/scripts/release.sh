#!/bin/sh
# Builds the four release binaries into host/minis-hostd/dist/ and writes their SHA256SUMS.
# Upload dist/* to the GitHub release tagged hostd-v<version>; install.sh downloads from there.
set -eu

usage() {
	echo "usage: $0 <version>   (for example: $0 0.1.0)" >&2
	exit 64
}

[ "$#" -eq 1 ] || usage
version=$1
case $version in
'' | v* | *[!A-Za-z0-9.+-]*) usage ;;
esac

go=${GO:-go}
command -v "$go" >/dev/null 2>&1 || {
	echo "$0: '$go' not found; put Go on PATH or set GO=/path/to/go" >&2
	exit 1
}

if command -v sha256sum >/dev/null 2>&1; then
	sha256() { sha256sum "$@"; }
elif command -v shasum >/dev/null 2>&1; then
	sha256() { shasum -a 256 "$@"; }
else
	echo "$0: neither sha256sum nor shasum found" >&2
	exit 1
fi

module_dir=$(cd "$(dirname "$0")/.." && pwd)
dist="$module_dir/dist"
mkdir -p "$dist"

assets=""
for target in darwin/arm64 darwin/amd64 linux/arm64 linux/amd64; do
	os=${target%/*}
	arch=${target#*/}
	asset="minis-hostd-$version-$os-$arch"
	echo "building $asset" >&2
	(
		cd "$module_dir"
		CGO_ENABLED=0 GOOS=$os GOARCH=$arch "$go" build -trimpath \
			-ldflags "-s -w -X main.version=$version" -o "$dist/$asset" .
	)
	assets="$assets $asset"
done

# shellcheck disable=SC2086 # asset names contain no spaces; splitting is intended.
(cd "$dist" && sha256 $assets >SHA256SUMS)
echo "wrote $dist/SHA256SUMS" >&2
