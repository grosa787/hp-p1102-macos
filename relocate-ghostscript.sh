#!/bin/sh
# Make a copied Homebrew/MacPorts Ghostscript executable inside the CUPS sandbox.
set -eu

DEST=$1
[ -x "$DEST/bin/gs" ] || { echo "Ghostscript copy is missing" >&2; exit 1; }
mkdir -p "$DEST/lib"

die() { printf 'Ghostscript relocation failed: %s\n' "$*" >&2; exit 1; }

# Each call runs in a subshell so recursion cannot overwrite the caller's
# current binary or library name. The old installer silently rewrote the wrong
# file when a dependency itself had dependencies.
relocate() (
    binary=$1
    otool -L "$binary" >/dev/null || die "Cannot inspect $binary"
    otool -L "$binary" | tail -n +2 | awk '{print $1}' | while IFS= read -r ref; do
        case "$ref" in
            /usr/lib/*|/System/*|@loader_path/*|@executable_path/*)
                continue ;;
        esac

        base=${ref##*/}
        [ "$base" = "$(basename "$binary")" ] && continue
        target="$DEST/lib/$base"

        if [ ! -f "$target" ]; then
            case "$ref" in
                @rpath/*)
                    source=''
                    for prefix in /opt/homebrew /usr/local /opt/local; do
                        if [ -f "$prefix/lib/$base" ]; then
                            source="$prefix/lib/$base"
                            break
                        fi
                    done
                    [ -n "$source" ] || die "Cannot locate $ref" ;;
                /*)
                    source=$ref
                    [ -f "$source" ] || die "Cannot locate $ref" ;;
                *) die "Unsupported library reference $ref" ;;
            esac
            cp -L "$source" "$target" || die "Cannot copy $source"
            chmod 755 "$target"
            relocate "$target"
            install_name_tool -id "@loader_path/../lib/$base" "$target" 2>/dev/null \
                || die "Cannot rewrite the ID of $target"
            codesign -f -s - "$target" >/dev/null 2>&1 \
                || die "Cannot sign $target"
        fi

        install_name_tool -change "$ref" "@loader_path/../lib/$base" "$binary" 2>/dev/null \
            || die "Cannot redirect $ref in $binary"
    done
    codesign -f -s - "$binary" >/dev/null 2>&1 || die "Cannot sign $binary"
)

relocate "$DEST/bin/gs"

for binary in "$DEST/bin/gs" "$DEST"/lib/*.dylib; do
    [ -f "$binary" ] || continue
    if otool -L "$binary" | tail -n +2 | awk '{print $1}' \
            | grep -E '^(\/opt\/homebrew\/|\/usr\/local\/|\/opt\/local\/|@rpath\/)'; then
        die "Homebrew/MacPorts library paths remain in $binary"
    fi
done

"$DEST/bin/gs" --version >/dev/null || die "The copied Ghostscript cannot run"
