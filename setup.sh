#!/bin/bash
# One-command setup for a USB-connected HP LaserJet Professional P1102.
set -euo pipefail

REPO_URL=https://github.com/grosa787/hp-p1102-macos.git
QUEUE=HP_LaserJet_P1102

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
say() { printf '==> %s\n' "$*"; }

[[ $(uname -s) == Darwin ]] || die 'This installer runs on macOS only.'
[[ $EUID -ne 0 ]] || die 'Run this command as your normal macOS user, without sudo.'

export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

say 'Checking the USB printer'
usb_devices=$(/usr/libexec/cups/backend/usb 2>/dev/null) \
    || die 'macOS could not enumerate USB printers.'
if ! grep -Eiq 'HP LaserJet.*P1102' <<< "$usb_devices"; then
    die 'HP LaserJet P1102 is not visible over USB. Connect and power on the printer, then retry.'
fi

if ! xcode-select -p >/dev/null 2>&1; then
    say 'Install the Apple command line tools in the macOS dialog'
    xcode-select --install || true
    for attempt in {1..240}; do
        xcode-select -p >/dev/null 2>&1 && break
        sleep 5
    done
    xcode-select -p >/dev/null 2>&1 \
        || die 'Apple command line tools were not installed within 20 minutes.'
fi

if ! command -v gs >/dev/null 2>&1; then
    if ! command -v brew >/dev/null 2>&1; then
        say 'Installing Homebrew from its official installer'
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
    fi
    command -v brew >/dev/null 2>&1 || die 'Homebrew installation did not make brew available.'
    say 'Installing Ghostscript with Homebrew'
    brew install ghostscript
fi

command -v gs >/dev/null 2>&1 || die 'Ghostscript is still unavailable.'
command -v git >/dev/null 2>&1 || die 'Git is unavailable.'

stage=$(mktemp -d -t hp-p1102-setup.XXXXXX)
trap 'rm -rf "$stage"' EXIT

say 'Downloading the P1102 driver source'
git clone --quiet --depth 1 "$REPO_URL" "$stage/repo"

say 'Installing the driver and making HP LaserJet P1102 the system default'
sudo "$stage/repo/install.sh" --default

# CUPS also permits a per-user default, which takes precedence over the
# system default. Set both so print dialogs launched by this user choose HP.
lpoptions -d "$QUEUE" >/dev/null
# macOS can otherwise override the fixed default with its "Last Printer Used"
# preference, even when both CUPS defaults point to HP.
defaults write org.cups.PrintingPrefs UseLastPrinter -bool false

lpstat -p "$QUEUE" >/dev/null || die 'The P1102 print queue was not created.'
lpstat -d | grep -Fq "$QUEUE" || die 'The P1102 is not the default printer.'
[ "$(defaults read org.cups.PrintingPrefs UseLastPrinter)" = 0 ] \
    || die 'macOS is still set to use the last printer.'
say 'Ready. Choose HP LaserJet P1102 in a print dialog, or print normally with Cmd+P.'
