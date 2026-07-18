#!/bin/sh

set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/ocom-auto-setup.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM

mock_bin="$temporary_directory/bin"
mock_log="$temporary_directory/cups.log"
install -d "$mock_bin"
: > "$mock_log"

for command_name in \
  id lp lpadmin lpinfo lpoptions lpstat cupsenable cupsaccept; do
  ln -s "$project_root/tests/mocks/cups-command" "$mock_bin/$command_name"
done

PATH="$mock_bin:/usr/bin:/bin" \
MOCK_CUPS_LOG="$mock_log" \
OCOM_CONFIG_FILE=/dev/null \
OCOM_SUPPORT_DIR="$project_root/scripts" \
OCOM_SAMPLE_DIR="$project_root/tests" \
OCOM_PPD_PATH="$project_root/OCOM_T4201_Linux.ppd" \
OCOM_TRANSLATOR_PATH="$project_root/zpl_to_tspl.py" \
"$project_root/scripts/ocom-t4201-setup" --automatic

grep -Fq \
  'lpadmin <-p> <OCOM_Ubuntu_Driver> <-E> <-v> <usb://LabelPrinter/OCBP-T4201?serial=TEST123>' \
  "$mock_log"
if grep -Fq 'OfficeJet' "$mock_log"; then
  printf 'ERROR: automatic setup selected the wrong USB printer\n' >&2
  exit 1
fi
grep -Fq '<document-format=application/vnd.ocom-zpl>' "$mock_log"
grep -Fq 'OCOM_T4201_test_label.zpl>' "$mock_log"

: > "$mock_log"
PATH="$mock_bin:/usr/bin:/bin" \
MOCK_CUPS_LOG="$mock_log" \
OCOM_CONFIG_FILE=/dev/null \
OCOM_SUPPORT_DIR="$project_root/scripts" \
OCOM_SAMPLE_DIR="$project_root/tests" \
OCOM_PPD_PATH="$project_root/OCOM_T4201_Linux.ppd" \
OCOM_TRANSLATOR_PATH="$project_root/zpl_to_tspl.py" \
"$project_root/scripts/ocom-t4201-setup" --automatic --no-test

if grep -q '^lp ' "$mock_log"; then
  printf 'ERROR: --no-test submitted a physical print job\n' >&2
  exit 1
fi

printf 'Automatic setup tests passed.\n'
