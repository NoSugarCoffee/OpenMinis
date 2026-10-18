#!/bin/sh
# Throwaway sshd for the opt-in MinisRemote integration tests.
# Usage: eval "$(sh up.sh)"   start and print env exports
#        sh up.sh down        remove the container
set -eu

NAME=minis-sshtest
PORT=2222
DIR=$(cd "$(dirname "$0")" && pwd)
KEY="$DIR/.key"

if [ "${1:-}" = "down" ]; then
    docker rm -f "$NAME" >/dev/null 2>&1 || true
    exit 0
fi

if [ ! -f "$KEY" ]; then
    ssh-keygen -q -t ed25519 -N "" -C minis-sshtest -f "$KEY"
fi

BUILD_DIR=$(mktemp -d)
trap 'rm -rf "$BUILD_DIR"' EXIT
cp "$DIR/Dockerfile" "$BUILD_DIR/Dockerfile"
cp "$KEY.pub" "$BUILD_DIR/authorized_keys"

docker build -q -t "$NAME" "$BUILD_DIR" >&2
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" -p "$PORT:22" "$NAME" >/dev/null

i=0
until nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -le 50 ] || { echo "sshd did not come up on port $PORT" >&2; exit 1; }
    sleep 0.2
done

echo "export MINIS_TEST_SSH_HOST=127.0.0.1 MINIS_TEST_SSH_PORT=$PORT MINIS_TEST_SSH_USER=dev MINIS_TEST_SSH_KEY=$KEY"
