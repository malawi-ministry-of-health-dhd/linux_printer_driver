#!/bin/sh

set -eu

queue=${QUEUE:-OCOM_Ubuntu_Driver}
method=${METHOD:-Direct}
page_size=${PAGE_SIZE:-w288h108}
paper_type=${PAPER_TYPE:-LabelGaps}
gap_mm=${GAP_MM:-3}
speed=${SPEED:-5}
darkness=${DARKNESS:-8}
filter_path=${FILTER_PATH:-/usr/lib/cups/filter/raster_to_tspl}
raster_generator=${RASTER_GENERATOR:-}

fail()
{
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

for command_name in lp lpoptions lpstat; do
  command -v "$command_name" >/dev/null 2>&1 ||
    fail "required command not found: $command_name"
done

[ -x "$filter_path" ] ||
  fail "installed filter not found or not executable: $filter_path"
[ -n "$raster_generator" ] && [ -x "$raster_generator" ] ||
  fail "test raster generator is not executable: $raster_generator"

lpstat -p "$queue" >/dev/null 2>&1 ||
  fail "CUPS queue '$queue' does not exist; run: sudo make setup"

queue_state=$(lpstat -p "$queue")
case "$queue_state" in
  *disabled*) fail "CUPS queue '$queue' is disabled: $queue_state" ;;
esac

defaults=$(lpoptions -p "$queue")
printf 'Testing queue: %s\n' "$queue"
printf 'Queue defaults: %s\n' "$defaults"
printf 'Submitting one physical 101.6 x 38.1 mm diagnostic label now.\n'

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/ocom-printer-test.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM
raster_file=$temporary_directory/test.raster
tspl_file=$temporary_directory/test.tspl

"$raster_generator" > "$raster_file"
"$filter_path" \
  1 "${USER:-tester}" "OCOM driver test" 1 \
  "PageSize=$page_size MediaMethod=$method PaperType=$paper_type GapsHeight=$gap_mm PrintSpeed=$speed Darkness=$darkness" \
  "$raster_file" > "$tspl_file"

[ -s "$tspl_file" ] || fail "the raster filter produced no TSPL output"

job_result=$(lp \
  -d "$queue" \
  -t "OCOM OCBP-T4201 driver test" \
  -o raw \
  "$tspl_file")

printf '%s\n' "$job_result"

attempt=0
while [ "$attempt" -lt 30 ]; do
  pending=$(lpstat -W not-completed -o "$queue" 2>/dev/null || true)
  [ -z "$pending" ] && break
  attempt=$((attempt + 1))
  sleep 1
done

pending=$(lpstat -W not-completed -o "$queue" 2>/dev/null || true)
if [ -n "$pending" ]; then
  printf 'ERROR: the test job did not leave the queue within 30 seconds:\n%s\n' \
    "$pending" >&2
  printf 'Inspect CUPS with: sudo journalctl -u cups -n 100 --no-pager\n' >&2
  exit 1
fi

printf 'CUPS accepted and completed the test job.\n'
printf 'Verify that one label printed with a barcode and JOHN DOE underneath.\n'
