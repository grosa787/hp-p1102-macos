#!/bin/sh
#
# Install a working print driver for the HP LaserJet Professional P1102
# (and close ZjStream relatives) on modern macOS, including Apple Silicon.
#
# Run with sudo:  sudo ./install.sh
#
# See README.md for why this is needed and how it works.
#
set -e

DEST=/Library/Printers/foo2zjs
PPDDIR=/Library/Printers/PPDs/Contents/Resources
PPDNAME=HP-LaserJet-P1102-foo2zjs.ppd
QUEUE=HP_LaserJet_P1102
PAPER=A4
MAKE_QUEUE=1
SET_DEFAULT=0
GS=""
HERE=$(cd "$(dirname "$0")" && pwd)

usage() {
    cat <<USAGE
Usage: sudo ./install.sh [options]

  --queue NAME    Name for the print queue      (default: $QUEUE)
  --paper SIZE    Default paper, A4 or Letter   (default: $PAPER)
  --no-queue      Install the driver but do not create a print queue
  --default       Make the new printer the macOS system default
  --gs PATH       Use this Ghostscript binary instead of auto-detecting
  -h, --help      Show this help

USAGE
    exit 0
}

while [ $# -gt 0 ]; do
    case "$1" in
        --queue)    QUEUE="$2"; shift 2 ;;
        --paper)    PAPER="$2"; shift 2 ;;
        --no-queue) MAKE_QUEUE=0; shift ;;
        --default)  SET_DEFAULT=1; shift ;;
        --gs)       GS="$2"; shift 2 ;;
        -h|--help)  usage ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

say()  { printf '==> %s\n' "$1"; }
info() { printf '    %s\n' "$1"; }
die()  { printf 'ERROR: %s\n' "$1" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "This installer is for macOS only."
[ "$(id -u)" -eq 0 ] || die "Please run with sudo:  sudo ./install.sh"
[ "$MAKE_QUEUE" -eq 1 ] || [ "$SET_DEFAULT" -eq 0 ] \
    || die "--default requires a print queue (remove --no-queue)."

case "$PAPER" in
    A4|a4)          PAPER=A4 ;;
    Letter|letter)  PAPER=Letter ;;
    *) die "--paper must be A4 or Letter (got '$PAPER')" ;;
esac

# ---------------------------------------------------------------------------
# 1. Build the foo2zjs rasteriser
# ---------------------------------------------------------------------------
say "Building the foo2zjs rasteriser"

CC=$(command -v clang 2>/dev/null || command -v cc 2>/dev/null || true)
[ -n "$CC" ] || die "No C compiler found. Install the Xcode command line tools:
       xcode-select --install"

BUILD=$(mktemp -d)
trap 'rm -rf "$BUILD"' EXIT

# Build universal (arm64 + x86_64) when the toolchain supports it, so the
# same install works on Apple Silicon and Intel. Fall back to native-only.
ARCHFLAGS="-arch arm64 -arch x86_64"
if ! $CC $ARCHFLAGS -O2 -o "$BUILD/foo2zjs" \
        "$HERE/src/foo2zjs.c" "$HERE/src/jbig.c" "$HERE/src/jbig_ar.c" \
        >/dev/null 2>&1; then
    info "universal build unavailable, building for $(uname -m) only"
    $CC -O2 -o "$BUILD/foo2zjs" \
        "$HERE/src/foo2zjs.c" "$HERE/src/jbig.c" "$HERE/src/jbig_ar.c" \
        || die "Failed to compile foo2zjs."
fi
info "built for: $(lipo -archs "$BUILD/foo2zjs" 2>/dev/null || uname -m)"

# ---------------------------------------------------------------------------
# 2. Locate Ghostscript
# ---------------------------------------------------------------------------
say "Locating Ghostscript"

if [ -z "$GS" ]; then
    for c in /usr/local/bin/gs /opt/homebrew/bin/gs /opt/local/bin/gs \
             "$(command -v gs 2>/dev/null || true)"; do
        [ -n "$c" ] && [ -x "$c" ] && { GS="$c"; break; }
    done
fi
[ -n "$GS" ] && [ -x "$GS" ] || die "Ghostscript not found. Install it first, e.g.:
       brew install ghostscript
   or download it from https://ghostscript.com/releases/
   then re-run, optionally with --gs /path/to/gs"

GSVER=$("$GS" --version 2>/dev/null) || die "Cannot run $GS"
GSRES=$("$GS" -h 2>/dev/null | awk '/Resource\/Init/ {print $1; exit}' \
        | sed 's@/Resource/Init$@@')
[ -n "$GSRES" ] && [ -d "$GSRES" ] \
    || die "Cannot determine the Ghostscript resource directory for $GS"
info "$GS (version $GSVER)"
info "resources: $GSRES"

# ---------------------------------------------------------------------------
# 3. Install everything under /Library/Printers
# ---------------------------------------------------------------------------
say "Installing into $DEST"

install -d -o root -g wheel -m 755 "$DEST/bin" "$DEST/filter" \
                                   "$DEST/share/ghostscript"
rm -rf "$DEST/lib"
install -d -o root -g wheel -m 755 "$DEST/lib"

install -o root -g wheel -m 755 "$BUILD/foo2zjs" "$DEST/bin/foo2zjs"

# The wrapper only uses PREFIX for colour profiles we never touch, but keep
# it pointing somewhere real rather than /usr.
sed 's@^PREFIX=.*@PREFIX='"$DEST"'@' "$HERE/src/foo2zjs-wrapper.in" \
    > "$DEST/bin/foo2zjs-wrapper"

# Upstream hardcodes GNU sed on Darwin. The only expression this driver ever
# feeds it is a plain POSIX s/// substitution, so fall back to BSD sed when
# gsed is absent. That removes the last Homebrew dependency.
sed 's@^Darwin)[[:space:]]*sed=gsed;;@Darwin)	if command -v gsed >/dev/null 2>\&1; then sed=gsed; else sed=sed; fi;;@' \
    "$HERE/src/foo2zjs-pstops.sh" > "$DEST/bin/foo2zjs-pstops"
grep -q 'command -v gsed' "$DEST/bin/foo2zjs-pstops" \
    || die "Failed to patch foo2zjs-pstops for BSD sed."

chown root:wheel "$DEST/bin/foo2zjs-wrapper" "$DEST/bin/foo2zjs-pstops"
chmod 755        "$DEST/bin/foo2zjs-wrapper" "$DEST/bin/foo2zjs-pstops"

# Bake the install location into the filter so DEST stays configurable.
sed "s@^DRVROOT=.*@DRVROOT=$DEST@" "$HERE/filter/foo2zjs-cups" \
    > "$DEST/filter/foo2zjs-cups"
chown root:wheel "$DEST/filter/foo2zjs-cups"
chmod 755        "$DEST/filter/foo2zjs-cups"

# ---------------------------------------------------------------------------
# 4. Copy Ghostscript inside the sandbox-reachable tree
# ---------------------------------------------------------------------------
say "Copying Ghostscript into $DEST (this is the part that makes it work)"

cp -L "$GS" "$DEST/bin/gs"
chown root:wheel "$DEST/bin/gs"
chmod 755 "$DEST/bin/gs"

rm -rf "$DEST/share/ghostscript"
install -d -o root -g wheel -m 755 "$DEST/share/ghostscript"
cp -R "$GSRES"/. "$DEST/share/ghostscript/"
chown -R root:wheel "$DEST/share/ghostscript"
chmod -R a+rX "$DEST/share/ghostscript"

# CUPS cannot reach Homebrew/MacPorts. Relocate every direct and transitive
# dependency and fail if any external path survives. A prior version silently
# produced header-only jobs because its recursive shell function lost its
# original binary name.
sh "$HERE/relocate-ghostscript.sh" "$DEST" \
    || die "Ghostscript dependencies could not be relocated."
NLIBS=$(find "$DEST/lib" -type f -name '*.dylib' | wc -l | tr -d ' ')
info "relocated $NLIBS bundled libraries"

install -d -o root -g wheel -m 755 "$PPDDIR"
install -o root -g wheel -m 644 "$HERE/ppd/$PPDNAME" "$PPDDIR/$PPDNAME"

if [ "$PAPER" = "Letter" ]; then
    # NB: -E is required. BSD sed does not support \| alternation in BREs,
    # and would silently make no change at all.
    sed -i '' -E 's@^\*Default(PageSize|PageRegion|ImageableArea|PaperDimension): A4@*Default\1: Letter@' \
        "$PPDDIR/$PPDNAME"
    grep -q '^\*DefaultPageSize: Letter' "$PPDDIR/$PPDNAME" \
        || die "Failed to switch the PPD default paper to Letter."
    info "default paper set to Letter"
fi

# ---------------------------------------------------------------------------
# 5. Self test -- run the filter the way the CUPS sandbox will run it
# ---------------------------------------------------------------------------
say "Self test (running the filter with an empty environment)"

cat > "$BUILD/t.ps" <<'PSEOF'
%!PS-Adobe-3.0
/Helvetica-Bold findfont 28 scalefont setfont
72 700 moveto (HP LaserJet P1102 - foo2zjs self test) show
showpage
PSEOF

env -i "$DEST/bin/gs" --version >/dev/null 2>&1 \
    || die "The copied Ghostscript at $DEST/bin/gs will not run.
   If it came from Homebrew or MacPorts its libraries may not have relocated
   cleanly. Install the self-contained build from https://ghostscript.com/releases/
   and re-run with --gs /usr/local/bin/gs"

# An empty environment is the point: it reproduces the sandbox in which a
# helper living in /usr/local silently disappears.
if ! env -i "$DEST/filter/foo2zjs-cups" 1 selftest selftest 1 \
        "PageSize=$PAPER" "$BUILD/t.ps" > "$BUILD/t.zjs" 2>"$BUILD/t.err"; then
    sed 's/^/    /' "$BUILD/t.err" >&2
    die "The filter failed to run."
fi

SIZE=$(wc -c < "$BUILD/t.zjs" | tr -d ' ')
if ! grep -aq 'JZJZ' "$BUILD/t.zjs"; then
    sed 's/^/    /' "$BUILD/t.err" >&2
    die "The filter produced $SIZE bytes but no ZjStream raster data.
   This is the classic silent failure: a PJL header with no page in it,
   which leaves the printer blinking forever. Check the errors above."
fi
if [ "$SIZE" -lt 2000 ]; then
    die "The filter produced only $SIZE bytes -- the page appears to be empty."
fi
info "produced $SIZE bytes of valid ZjStream. Rendering works."

# ---------------------------------------------------------------------------
# 6. Create the print queue
# ---------------------------------------------------------------------------
if [ "$MAKE_QUEUE" -eq 1 ]; then
    say "Creating the print queue '$QUEUE'"
    URI=$(/usr/libexec/cups/backend/usb 2>/dev/null \
          | grep -i 'P1102' | awk '{print $2}' | head -1)
    if [ -z "$URI" ]; then
        [ "$SET_DEFAULT" -eq 0 ] || die "No supported printer found on USB; cannot make it the default."
        info "No supported printer found on USB -- skipping queue creation."
        info "Plug the printer in, power it on, then run:"
        info "  sudo $0 --queue $QUEUE"
    else
        info "$URI"
        DEFAULT_BEFORE=$(lpstat -d 2>/dev/null | sed 's/.*: //')
        lpadmin -p "$QUEUE" -v "$URI" -P "$PPDDIR/$PPDNAME" \
                -D "HP LaserJet Professional P1102" -L "USB" \
                -o printer-is-shared=false -E
        cupsenable "$QUEUE" 2>/dev/null || true
        cupsaccept "$QUEUE" 2>/dev/null || true
        if [ "$SET_DEFAULT" -eq 1 ]; then
            lpadmin -d "$QUEUE" || die "Could not set '$QUEUE' as the default printer."
            info "system default printer is now '$QUEUE'"
        # Adding a queue can steal the system default; put it back.
        elif [ -n "$DEFAULT_BEFORE" ] && [ "$DEFAULT_BEFORE" != "$QUEUE" ]; then
            lpadmin -d "$DEFAULT_BEFORE" 2>/dev/null || true
            info "left the default printer as '$DEFAULT_BEFORE'"
        fi
        info "queue ready"
    fi
fi

echo
say "Done."
echo
echo "  Print a test page with:"
echo "    lp -d $QUEUE /path/to/file.pdf"
echo
echo "  If the printer ever stalls mid-job (blinking green light), power-cycle"
echo "  it: a partial job leaves it waiting and swallowing everything after."
echo
