# OCOM OCBP-T4201 Linux CUPS driver

This is a lightweight CUPS raster-to-TSPL2 filter, host-side ZPL-to-TSPL2
translator, and Linux PPD for the LabelPrinter/OCOM OCBP-T4201. Its hardware
parameters were taken from the working macOS manufacturer driver and its target
media is configured for:

- 203 × 203 dpi
- TSPL2
- Default media: 4 × 1.5 inches (101.6 × 38.1 mm), full bleed
- Default label gap: 3 mm
- Default speed: 5 inches/second
- Default darkness: 8

The 25 mm roll core is a physical media property and needs no CUPS or TSPL
setting. The PPD also includes the manufacturer's 2 × 4, 2 × 5, 3 × 4, 3 × 6,
4 × 4, and 4 × 6 inch media sizes.

## Automatic GitHub builds and releases

Every push to GitHub runs `.github/workflows/build-deb.yml`. The workflow:

1. Builds and tests the driver on an Ubuntu 22.04 amd64 runner.
2. Creates the installable Debian package.
3. Verifies its package metadata and Linux ELF filter.
4. Translates the included ZPL label as a smoke test.
5. Uploads the `.deb` and `SHA256SUMS` as a GitHub Actions artifact retained
   for 30 days.
6. For pushes to `main`, creates a uniquely tagged GitHub prerelease containing
   the `.deb` and checksum.

Open the repository's **Releases** page to download packages produced from
`main`. Each push creates a prerelease tag such as `build-42` and a unique
package version such as `1.0.4+git42.a1b2c3d`.

Pushing a version tag beginning with `v`, such as `v1.2.0`, creates a normal
GitHub Release named `OCOM OCBP-T4201 driver 1.2.0` containing package version
`1.2.0`:

```sh
git tag v1.2.0
git push origin v1.2.0
```

Builds from other branches remain downloadable from the corresponding
**Actions** run but do not create repository releases.

The workflow can also be started manually from **Actions → Build and release
Debian package → Run workflow**. Manual runs build an Actions artifact but do
not publish a release.

## Install the Debian package

The `.deb` performs the full setup automatically. During its first
installation it:

1. Installs the CUPS raster filter, PPD, ZPL translator, and MIME rules.
2. Starts or restarts CUPS.
3. Detects the connected USB label printer and creates
   `OCOM_Ubuntu_Driver`.
4. Applies direct-thermal, 101.6 × 38.1 mm, 3 mm gap, speed 5, and darkness 8
   defaults.
5. Submits the included ZPL barcode test label through CUPS.

Build an amd64 Ubuntu package from macOS, Linux, or another Docker host:

```sh
make deb-docker
```

The package is written to:

```text
dist/ocom-ocbp-t4201-driver_1.0.4_amd64.deb
```

Copy it to the Ubuntu computer, connect and power on the printer, then install
it with `apt` so dependencies are resolved automatically:

```sh
sudo apt install ./ocom-ocbp-t4201-driver_1.0.4_amd64.deb
```

If the Ubuntu computer uses ARM64:

```sh
make deb-docker DEB_PLATFORM=linux/arm64
sudo apt install ./ocom-ocbp-t4201-driver_1.0.4_arm64.deb
```

The package remains successfully installed when no printer is connected.
Connect it later and finish configuration with:

```sh
sudo ocom-t4201-setup
```

Useful installed setup commands:

```sh
# Configure and print the ZPL test label
sudo ocom-t4201-setup

# Configure without printing
sudo ocom-t4201-setup --no-test

# Select a printer when multiple USB printers are connected
lpinfo -v | grep -i usb
sudo ocom-t4201-setup --uri 'usb://THE_EXACT_URI'
```

Persistent package defaults can be changed in
`/etc/default/ocom-t4201-driver`.

On Debian or Ubuntu, the package can also be built natively:

```sh
sudo apt install -y build-essential cups-client dpkg-dev \
  libcups2-dev libcupsimage2-dev python3
make deb
```

## Build on Ubuntu

Install the CUPS development headers and compile:

```sh
sudo apt update
sudo apt install -y cups cups-filters ghostscript python3 build-essential libcups2-dev libcupsimage2-dev
make
```

The equivalent direct compiler command is:

```sh
gcc -O2 -Wall -Wextra -Wpedantic \
  $(cups-config --cflags) raster_to_tspl.c -o raster_to_tspl \
  $(cups-config --libs) -lcupsimage
```

## Install

```sh
sudo install -o root -g root -m 0755 \
  raster_to_tspl /usr/lib/cups/filter/raster_to_tspl
sudo install -o root -g root -m 0755 \
  zpl_to_tspl.py /usr/lib/cups/filter/zpl_to_tspl
sudo install -o root -g root -m 0644 \
  OCOM_T4201_Linux.ppd /usr/share/ppd/OCOM_T4201_Linux.ppd
sudo install -o root -g root -m 0644 \
  mime/ocom-zpl.types /usr/share/cups/mime/ocom-zpl.types
sudo install -o root -g root -m 0644 \
  mime/ocom-zpl.convs /usr/share/cups/mime/ocom-zpl.convs
sudo systemctl restart cups
```

Alternatively, after installing the dependencies, one command can build,
validate, install, detect a single connected USB printer, configure the queue,
and physically print the included ZPL test label:

```sh
sudo make setup METHOD=Direct
```

The printed 101.6 × 38.1 mm label contains a Code 128 `JOHNDOE` barcode with
`JOHN DOE` underneath. To install and configure without consuming a label:

```sh
sudo make setup METHOD=Direct SETUP_TEST=none
```

The setup target deliberately stops if no USB printer or more than one USB
printer is present. If several are connected, select the URI explicitly:

```sh
lpinfo -v | grep -i usb
sudo make setup URI='usb://THE_EXACT_URI_FROM_LPINFO'
```

The setup defaults are a queue named `OCOM_Ubuntu_Driver`, direct thermal
printing, 101.6 × 38.1 mm gap labels, a 3 mm gap, speed 5, and darkness 8.
Settings can be overridden, for example:

```sh
sudo make setup METHOD=Transfer DARKNESS=10 SPEED=4
```

Find the printer URI:

```sh
lpinfo -v | grep -i usb
```

Create the queue, replacing the URI with the exact value reported by `lpinfo`:

```sh
sudo lpadmin -p OCOM_Ubuntu_Driver -E \
  -v 'usb://YOUR_LINUX_USB_URI' \
  -P /usr/share/ppd/OCOM_T4201_Linux.ppd
sudo lpoptions -p OCOM_Ubuntu_Driver -o PageSize=w288h108
sudo cupsenable OCOM_Ubuntu_Driver
sudo cupsaccept OCOM_Ubuntu_Driver
```

Verify the queue and its defaults:

```sh
lpstat -p -d
lpoptions -p OCOM_Ubuntu_Driver -l
```

## Print a physical driver test

The following command generates a known one-bit CUPS raster page, converts it
with the installed raster-to-TSPL filter, and submits the TSPL through the
configured CUPS USB queue:

```sh
make test-printer
```

This physically prints one label. The command verifies that the queue and
installed filter exist, runs the filter using the configured media, gap, speed,
and darkness, and waits up to 30 seconds for the raw job to leave the queue. On
the 101.6 × 38.1 mm label, check that the barcode is complete and `JOHN DOE`
appears underneath.

Use the same overrides as setup when testing a non-default configuration:

```sh
make test-printer METHOD=Transfer DARKNESS=10 SPEED=4
```

## Sample PDF and raw TSPL2 commands

Two printable samples are included:

- `tests/OCOM_T4201_test_label.pdf` is a true 4 × 1.5 inch PDF that exercises
  CUPS document rendering, the PPD, and the raster-to-TSPL filter.
- `tests/OCOM_T4201_test_commands.tspl` is a readable TSPL2 program containing
  the page setup, border, Code 128 barcode for `JOHNDOE`, `JOHN DOE`
  underneath, and the print command.
- `tests/OCOM_T4201_test_label.zpl` contains the equivalent source label in
  ZPL II.

Print the PDF through the complete driver pipeline:

```sh
make test-pdf
```

Send the TSPL2 commands directly to the printer, bypassing document rendering:

```sh
make test-tspl
```

Both commands physically print one label and wait for the job to leave the
CUPS queue. The TSPL test target converts the sample to CRLF command endings
and applies `METHOD`, `GAP_MM`, `SPEED`, and `DARKNESS` overrides before
printing. For example:

```sh
make test-tspl METHOD=Transfer SPEED=4 DARKNESS=10
```

To regenerate the PDF from its dependency-free source:

```sh
make sample-pdf
```

## ZPL input support

The OCBP-T4201 does not receive ZPL directly. The installed `zpl_to_tspl`
filter translates supported ZPL commands on Ubuntu and sends native TSPL to
the printer.

Submit the included ZPL sample through the complete CUPS ZPL-to-TSPL conversion
chain and physically print one label:

```sh
make test-zpl
```

Translate a ZPL file without printing:

```sh
make translate-zpl INPUT=/path/to/label.zpl OUTPUT=/tmp/label.tspl
```

After `sudo make setup`, ZPL may also be submitted through CUPS. The `.zpl`
extension is detected automatically; the document format can be supplied
explicitly when needed:

```sh
lp -d OCOM_Ubuntu_Driver \
  -o document-format=application/vnd.ocom-zpl \
  /path/to/label.zpl
```

The translator supports:

- Label boundaries, size, home/shift, field origin, and field typesetting:
  `^XA`, `^XZ`, `^PW`, `^LL`, `^LH`, `^LS`, `^LT`, `^FO`, `^FT`
- Built-in fonts and text: `^A*`, `^CF`, `^FD`, `^FH`, `^FS`, `^FW`
- Code 128, Code 39, and QR: `^BY`, `^BC`, `^B3`, `^BQ`
- Boxes, lines, circles, and uncompressed ASCII graphics:
  `^GB`, `^GC`, `^GFA`
- Copies, speed, darkness, and orientation: `^PQ`, `^PR`, `^MD`, `~SD`, `^PO`

The CUPS `PageSize` remains authoritative for physical media. `^PW` and `^LL`
are accepted as ZPL layout declarations, but they cannot enlarge or shrink the
TSPL `SIZE` command beyond the selected label. This prevents a template with
`^LL450` from feeding 56.3 mm when the configured label is only 38.1 mm high.
ZPL font dimensions are mapped to the closest native TSPL bitmap font and
multiplier combination to avoid visibly stretched text.

This is a bounded translator rather than a complete ZPL firmware emulator.
Compressed `^GF` graphics, stored/downloaded objects (`~DG`, `^XG`, `^XF`),
advanced field blocks, and printer-management commands are not reproduced.
Potentially visible omissions generate CUPS warnings instead of being accepted
silently.

Print a PDF at its original size (do not select "fit to page"):

```sh
lp -d OCOM_Ubuntu_Driver -o PageSize=w288h108 label.pdf
```

If this is a direct-thermal printer with no ribbon installed, select **Direct
Thermal** in the printer options or use `-o MediaMethod=Direct`.

## Filter behavior

The filter reads chunked CUPS Raster pages. The PPD requests one-bit `K` raster
data, so CUPS performs normal document rendering and halftoning. Each page is
streamed to a TSPL `BITMAP` command one scan line at a time; it does not retain
the entire page in memory. It also safely accepts 8-bit K/W, RGB, and common
CMY/CMYK raster input for diagnostic use.

The standard CUPS invocation is:

```text
raster_to_tspl job-id user title copies options [raster-file]
```

For local filter testing, a CUPS raster stream may also be piped directly to
stdin.
