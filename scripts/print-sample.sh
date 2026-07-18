#!/bin/sh

set -eu

sample_type=${1:-}
sample_file=${SAMPLE_FILE:-}
queue=${QUEUE:-OCOM_Ubuntu_Driver}
method=${METHOD:-Direct}
page_size=${PAGE_SIZE:-w288h108}
paper_type=${PAPER_TYPE:-LabelGaps}
gap_mm=${GAP_MM:-3}
speed=${SPEED:-5}
darkness=${DARKNESS:-8}
translator_path=${TRANSLATOR_PATH:-/usr/lib/cups/filter/zpl_to_tspl}

fail()
{
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

case "$sample_type" in
  pdf|tspl|zpl) ;;
  *) fail "usage: print-sample.sh pdf|tspl|zpl" ;;
esac

case "$method" in
  Direct) ribbon=OFF ;;
  Transfer) ribbon=ON ;;
  *) fail "METHOD must be Direct or Transfer" ;;
esac

for command_name in lp lpstat; do
  command -v "$command_name" >/dev/null 2>&1 ||
    fail "required command not found: $command_name"
done

[ -n "$sample_file" ] && [ -r "$sample_file" ] ||
  fail "sample file is not readable: $sample_file"

lpstat -p "$queue" >/dev/null 2>&1 ||
  fail "CUPS queue '$queue' does not exist; run: sudo make setup"

queue_state=$(lpstat -p "$queue")
case "$queue_state" in
  *disabled*) fail "CUPS queue '$queue' is disabled: $queue_state" ;;
esac

printf 'Submitting one physical %s test label to %s.\n' \
  "$(printf '%s' "$sample_type" | tr '[:lower:]' '[:upper:]')" "$queue"

if [ "$sample_type" = "pdf" ]; then
  job_result=$(lp \
    -d "$queue" \
    -t "OCOM OCBP-T4201 PDF test" \
    -o "PageSize=$page_size" \
    -o "MediaMethod=$method" \
    -o "PaperType=$paper_type" \
    -o "GapsHeight=$gap_mm" \
    -o "PrintSpeed=$speed" \
    -o "Darkness=$darkness" \
    -o fit-to-page=false \
    -o scaling=100 \
    "$sample_file")
elif [ "$sample_type" = "tspl" ]; then
  temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/ocom-tspl-test.XXXXXX")
  trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM
  prepared_tspl=$temporary_directory/test.tspl

  awk \
    -v ribbon="$ribbon" \
    -v gap="$gap_mm" \
    -v speed="$speed" \
    -v darkness="$darkness" '
      /^GAP / { printf "GAP %s.0 mm,0.0 mm\r\n", gap; next }
      /^SPEED / { printf "SPEED %s\r\n", speed; next }
      /^DENSITY / { printf "DENSITY %s\r\n", darkness; next }
      /^SET RIBBON / { printf "SET RIBBON %s\r\n", ribbon; next }
      { sub(/\r$/, ""); printf "%s\r\n", $0 }
    ' "$sample_file" > "$prepared_tspl"

  job_result=$(lp \
    -d "$queue" \
    -t "OCOM OCBP-T4201 raw TSPL test" \
    -o raw \
    "$prepared_tspl")
else
  [ -x "$translator_path" ] ||
    fail "installed ZPL translator not found or not executable: $translator_path"

  job_result=$(lp \
    -d "$queue" \
    -t "OCOM OCBP-T4201 ZPL-to-TSPL test" \
    -o document-format=application/vnd.ocom-zpl \
    -o "PageSize=$page_size" \
    -o "MediaMethod=$method" \
    -o "PaperType=$paper_type" \
    -o "GapsHeight=$gap_mm" \
    -o "PrintSpeed=$speed" \
    -o "Darkness=$darkness" \
    "$sample_file")
fi

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

printf 'CUPS accepted and completed the %s test job.\n' "$sample_type"
