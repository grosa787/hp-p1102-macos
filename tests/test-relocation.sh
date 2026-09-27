#!/bin/sh
# Regression test: a copied Ghostscript must not link to Homebrew/MacPorts.
set -eu

HERE=$(cd "$(dirname "$0")/.." && pwd)
GS=$(command -v gs) || { echo 'Ghostscript is required for this test' >&2; exit 1; }
STAGE=$(mktemp -d -t p1102-relocation.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT HUP INT TERM

mkdir -p "$STAGE/bin"
cp -L "$GS" "$STAGE/bin/gs"
sh "$HERE/relocate-ghostscript.sh" "$STAGE"

if otool -L "$STAGE/bin/gs" "$STAGE"/lib/*.dylib \
        | grep -E '(/opt/homebrew/|/usr/local/|/opt/local/|@rpath/)'; then
    echo 'External dynamic library reference remains' >&2
    exit 1
fi

env -i "$STAGE/bin/gs" --version >/dev/null
echo 'Ghostscript relocation: PASS'
