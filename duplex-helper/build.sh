#!/bin/sh
#
# Build "Duplex Helper.app" with just the Xcode command line tools (no Xcode).
#
#   ./build.sh              -> build/Duplex Helper.app
#   ./build.sh --install    -> also copy it to ~/Applications
#
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
NAME="Duplex Helper"
BUILD="$HERE/build"
APP="$BUILD/$NAME.app"
MIN=13.0

say() { printf '==> %s\n' "$1"; }

command -v swiftc >/dev/null 2>&1 || {
    echo "swiftc not found. Install the Xcode command line tools: xcode-select --install" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD/obj"

SOURCES=$(ls "$HERE"/Sources/*.swift)
FLAGS="-O -swift-version 5 -module-name DuplexHelper"

say "Compiling"
build_arch() {
    swiftc $FLAGS -target "$1-apple-macos$MIN" $SOURCES -o "$BUILD/obj/$NAME-$1"
}
if build_arch arm64 2>"$BUILD/obj/err-arm64" && build_arch x86_64 2>"$BUILD/obj/err-x86_64"; then
    lipo -create "$BUILD/obj/$NAME-arm64" "$BUILD/obj/$NAME-x86_64" -output "$APP/Contents/MacOS/$NAME"
    printf '    universal: %s\n' "$(lipo -archs "$APP/Contents/MacOS/$NAME")"
else
    # Show errors from the native build, then retry natively so they surface.
    ARCH=$(uname -m)
    swiftc $FLAGS -target "$ARCH-apple-macos$MIN" $SOURCES -o "$APP/Contents/MacOS/$NAME"
    printf '    native only: %s\n' "$ARCH"
fi

say "Bundling"
cp "$HERE/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if command -v iconutil >/dev/null 2>&1; then
    ICONSET="$BUILD/obj/AppIcon.iconset"
    rm -rf "$ICONSET"; mkdir -p "$ICONSET"
    swift "$HERE/Resources/MakeIcon.swift" "$BUILD/obj/icon-1024.png" 2>/dev/null || true
    if [ -f "$BUILD/obj/icon-1024.png" ]; then
        for s in 16 32 128 256 512; do
            sips -z $s $s "$BUILD/obj/icon-1024.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
            d=$((s * 2))
            sips -z $d $d "$BUILD/obj/icon-1024.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
        done
        iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" && printf '    icon OK\n'
    fi
fi

# Ad-hoc signature: required to launch on Apple Silicon. Finder-style
# extended attributes on any file inside the bundle make codesign refuse
# ("resource fork, Finder information, or similar detritus"), so strip them.
xattr -cr "$APP"
if codesign --force --deep --sign - \
        --identifier io.github.cragkhit.duplex-helper "$APP" 2>"$BUILD/obj/codesign.log"; then
    printf '    signed (ad hoc)\n'
else
    printf '    WARNING: codesign failed:\n'; sed 's/^/      /' "$BUILD/obj/codesign.log"
fi

say "Built: $APP"

if [ "$1" = "--install" ]; then
    mkdir -p "$HOME/Applications"
    rm -rf "$HOME/Applications/$NAME.app"
    cp -R "$APP" "$HOME/Applications/"
    say "Installed: $HOME/Applications/$NAME.app"
fi
