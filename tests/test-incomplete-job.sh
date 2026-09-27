#!/bin/sh
# A failed rasterizer must not send a partial job to the printer.
set -eu

HERE=$(cd "$(dirname "$0")/.." && pwd)
STAGE=$(mktemp -d -t p1102-incomplete.XXXXXX)
trap 'rm -rf "$STAGE"' EXIT HUP INT TERM
mkdir -p "$STAGE/bin"

sed "s@^DRVROOT=.*@DRVROOT=$STAGE@" "$HERE/filter/foo2zjs-cups" \
    > "$STAGE/filter"
cat > "$STAGE/bin/foo2zjs-wrapper" <<'WRAPPER'
#!/bin/sh
dd if=/dev/zero bs=400 count=1 2>/dev/null
WRAPPER
chmod 755 "$STAGE/filter" "$STAGE/bin/foo2zjs-wrapper"

if TMPDIR="$STAGE" "$STAGE/filter" 1 tester test 1 PageSize=A4 /dev/null \
        > "$STAGE/output" 2> "$STAGE/error"; then
    echo 'The filter accepted a header-only job' >&2
    exit 1
fi
[ ! -s "$STAGE/output" ] || {
    echo 'The filter sent partial output to the printer' >&2
    exit 1
}
grep -q 'no complete page' "$STAGE/error"
echo 'Incomplete job rejection: PASS'
