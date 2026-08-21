#!/bin/sh
#
# Remove the foo2zjs driver for the HP LaserJet Professional P1102.
# Run with sudo:  sudo ./uninstall.sh
#
set -e

DEST=/Library/Printers/foo2zjs
PPDDIR=/Library/Printers/PPDs/Contents/Resources
PPDNAME=HP-LaserJet-P1102-foo2zjs.ppd
QUEUE=HP_LaserJet_P1102

while [ $# -gt 0 ]; do
    case "$1" in
        --queue) QUEUE="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: sudo ./uninstall.sh [--queue NAME]"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

say() { printf '==> %s\n' "$1"; }

[ "$(id -u)" -eq 0 ] || { echo "Please run with sudo." >&2; exit 1; }

say "Removing the print queue '$QUEUE'"
lpadmin -x "$QUEUE" 2>/dev/null || echo "    (no such queue)"

say "Removing $DEST"
rm -rf "$DEST"

say "Removing the PPD"
rm -f "$PPDDIR/$PPDNAME"

echo
say "Done. Ghostscript itself was not touched."
