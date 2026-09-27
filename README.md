# HP LaserJet P1102 driver for modern macOS

A working print driver for the **HP LaserJet Professional P1102** on current
macOS, including Apple Silicon — built on the open-source
[foo2zjs](http://foo2zjs.rkkda.com/) rasteriser.

HP never shipped an Apple Silicon driver for this printer, and macOS no longer
bundles one. This installs a self-contained driver and creates a print queue.

Verified on macOS 26.5 (Apple Silicon) with a P1102 over USB.

This fork adds a one-command setup that installs missing prerequisites, creates
the USB print queue, and makes the P1102 the default printer. The driver itself
was developed by [cragkhit](https://github.com/cragkhit/hp-p1102-macos) using
the open-source `foo2zjs` rasteriser.

## Why a special driver is needed

The P1102 is a *host-based* printer. It reports:

```
MFG:Hewlett-Packard;MDL:HP LaserJet Professional P1102;CMD:ZJS,PJL
```

`ZJS` is Zenographics ZjStream. The printer has **no PostScript and no PCL
interpreter** — it cannot rasterise anything itself. The Mac must render each
page to a compressed bitmap and send that. No generic, PostScript or PCL driver
can ever drive it, which is why "add printer" with a generic driver produces
nothing.

`foo2zjs` does that rendering. This repo packages it for macOS.

## One-command setup

Connect and power on the P1102, then run this single command in Terminal:

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/grosa787/hp-p1102-macos/main/setup.sh)"
```

The setup may ask for your macOS administrator password. It installs Apple's
command line tools, Homebrew, or Ghostscript only if missing, then creates the
**HP_LaserJet_P1102** queue and makes it the default for your user and the Mac.
The printer stays connected by USB. The setup does not print a test page.

If you prefer to inspect the script before running it, read
[`setup.sh`](setup.sh) and [`install.sh`](install.sh) in this repository.

## Manual installation

```sh
git clone https://github.com/grosa787/hp-p1102-macos.git
cd hp-p1102-macos
sudo ./install.sh --default
lpoptions -d HP_LaserJet_P1102
```

Then print to the **HP_LaserJet_P1102** queue from any app.

Options:

```
--queue NAME    name for the print queue      (default: HP_LaserJet_P1102)
--paper SIZE    default paper, A4 or Letter   (default: A4)
--no-queue      install the driver only
--default       make the new printer the macOS system default
--gs PATH       use a specific Ghostscript binary
```

To remove everything:

```sh
sudo ./uninstall.sh
```

## Requirements

- **Xcode command line tools** — `xcode-select --install`
  (the rasteriser is compiled from source at install time)
- **Ghostscript** — `brew install ghostscript`, or the self-contained build
  from [ghostscript.com](https://ghostscript.com/releases/)

Nothing else. No Homebrew dependency at runtime: the installer copies
everything it needs into `/Library/Printers/foo2zjs`, so uninstalling Homebrew
or Ghostscript later will not break printing.

## The one thing that makes this tricky

**macOS runs CUPS filters inside a sandbox that cannot reach `/usr/local`,
`/opt/homebrew` or `/opt/local`.**

The P1102 also expects a **1200 × 600 dpi** raster in this driver. Feeding a
600 × 600 dpi bitmap directly to `foo2zjs` without changing its resolution
setting makes the printed content about half as wide. The installed wrapper
renders and encodes at the same resolution, preserving the PDF's proportions.

A filter that calls Ghostscript by name works perfectly when you test it by
hand in a terminal, then fails inside CUPS with `gs: command not found`. The
failure is *silent and misleading*: the wrapper carries on and emits a
structurally valid PJL job header containing **no raster data at all**. The
printer opens a job, waits forever for page data, and blinks its green Ready
light. It looks exactly like a hardware or firmware fault. It isn't.

The installer copies Ghostscript, its resources, and all non-system dynamic
libraries into `/Library/Printers/foo2zjs`. It rewrites each library reference
to point to that directory and refuses to finish if a Homebrew or MacPorts
path remains. An `env -i` self test checks rendering, while the installed CUPS
filter buffers each job and rejects incomplete output before it reaches the
printer. Installation also sends a sample page through a temporary local CUPS
queue and checks the rendered bytes without using paper. A plain `env -i` test
alone cannot reproduce the macOS CUPS sandbox.

## Layout once installed

```
/Library/Printers/foo2zjs/
├── bin/
│   ├── foo2zjs              rasteriser (universal arm64 + x86_64)
│   ├── foo2zjs-wrapper      renders PostScript via gs, then foo2zjs
│   ├── foo2zjs-pstops       PostScript pre-filter
│   └── gs                   private copy of Ghostscript
├── lib/                     any dylibs gs needs, relocated
├── share/ghostscript/       Ghostscript resource tree
└── filter/foo2zjs-cups      CUPS filter, maps print options to foo2zjs

/Library/Printers/PPDs/Contents/Resources/HP-LaserJet-P1102-foo2zjs.ppd
```

The print path is:

```
app → PDF → cgpdftops → PostScript → foo2zjs-cups → gs → foo2zjs → ZjStream → USB
```

Supported in the print dialog: Page Size, Media Source, Media Type, Print
Density, and Draft mode. The P1102 is 600 dpi mono and has no duplexer.

## Troubleshooting

**Printer blinks green and nothing prints.** A job died partway and the printer
is still waiting for the rest of it; it will swallow everything sent afterwards.
Power-cycle the printer. To confirm what it thinks is happening, ask it:

```sh
printf '\033%%-12345X@PJL\n@PJL INFO STATUS\n\033%%-12345X' > /tmp/probe.pjl
URI=$(/usr/libexec/cups/backend/usb | grep -i P1102 | awk '{print $2}')
DEVICE_URI="$URI" /usr/libexec/cups/backend/usb 1 me probe 1 "" /tmp/probe.pjl 3>&1
```

`CODE=10023` with `ONLINE=TRUE` means "busy waiting for data", not a fault.
Codes in the 40xxx/41xxx range are real conditions (cover, jam, paper, toner).

**Diagnosing a failing job.** Turn on CUPS debug logging, print, then read the
log — the byte count tells you immediately whether raster data was produced:

```sh
cupsctl --debug-logging
lp -d HP_LaserJet_P1102 somefile.pdf
grep -a "Job N" /var/log/cups/error_log | grep -aE "not found|bytes of print data"
cupsctl --no-debug-logging
```

A few hundred bytes means the page never rendered. Tens of KB means it did.

**Nothing found on USB.** Some P1102 units ship with *HP Smart Install*, which
presents a fake USB CD-ROM. If `/usr/libexec/cups/backend/usb` does not list the
printer, Smart Install may need disabling with HP's `SIUtility` (Windows) or
`usb_modeswitch` (Linux).

## Two-sided printing

The P1102 has no duplexer. [**Duplex Helper**](duplex-helper/) is a small
native app in this repo that prints the odd pages, shows you how to reinsert
the stack, then prints the even pages on the backs — with a calibration step
that works out the right reinsertion for any printer.

```sh
cd duplex-helper && ./build.sh --install
```

## Other printers

The same driver covers other ZjStream models. They need different model flags,
set in `filter/foo2zjs-cups` (`-z2` here) and a matching PPD:

| Printer | Flags |
|---|---|
| LaserJet Pro P1102 / P1102w / P1566 / P1606dn | `-P -z2 -L0` |
| LaserJet 1018 / 1020 / 1022 / P2035 | `-P -z1 -L0` |
| LaserJet 1000 / 1005 | `-P` |

Note the LaserJet 1000/1005/1018/1020 and P1005/P1006/P1505 additionally need a
firmware blob uploaded on every power-on. **The P1102 does not** — it has its
firmware in flash.

## Licence

`foo2zjs` is © Rick Richardson and contributors, GPL-2.0-or-later. The vendored
sources in `src/` are unmodified upstream; the installer patches one line at
install time so BSD `sed` is used when GNU `sed` is absent. `LICENSE` is
GPL-2.0. Ghostscript is *not* redistributed here — the installer copies whatever
copy is already on the machine.
