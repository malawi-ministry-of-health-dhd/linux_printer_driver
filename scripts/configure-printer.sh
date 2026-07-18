#!/bin/sh

set -eu

queue=${QUEUE:-OCOM_Ubuntu_Driver}
uri=${URI:-}
method=${METHOD:-Direct}
page_size=${PAGE_SIZE:-w288h108}
paper_type=${PAPER_TYPE:-LabelGaps}
gap_mm=${GAP_MM:-3}
speed=${SPEED:-5}
darkness=${DARKNESS:-8}
ppd_path=${PPD_PATH:-}

fail()
{
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[ "$(id -u)" -eq 0 ] ||
  fail "configuration requires root; run: sudo ocom-t4201-setup"

for command_name in lpadmin lpinfo cupsenable cupsaccept lpoptions; do
  command -v "$command_name" >/dev/null 2>&1 ||
    fail "required command not found: $command_name"
done

[ -n "$ppd_path" ] && [ -r "$ppd_path" ] ||
  fail "PPD file is not readable: $ppd_path"

case "$method" in
  Direct|Transfer) ;;
  *) fail "METHOD must be Direct or Transfer" ;;
esac

if [ -z "$uri" ]; then
  detected_uris=$(lpinfo -v | awk '$1 == "direct" && $2 ~ /^usb:\/\// { print $2 }')

  # USB printer URIs are percent-encoded and therefore contain no shell spaces.
  # Splitting here lets us safely distinguish zero, one, and multiple printers.
  set -- $detected_uris

  case "$#" in
    0)
      fail "no USB printer detected; connect and power on the printer, then run lpinfo -v"
      ;;
    1)
      uri=$1
      ;;
    *)
      preferred_uri=
      preferred_count=0
      for detected_uri in "$@"; do
        lowercase_uri=$(printf '%s' "$detected_uri" | tr '[:upper:]' '[:lower:]')
        case "$lowercase_uri" in
          *ocom*|*ocbp-t4201*|*labelprinter*|*label%20printer*)
            preferred_uri=$detected_uri
            preferred_count=$((preferred_count + 1))
            ;;
        esac
      done

      if [ "$preferred_count" -eq 1 ]; then
        uri=$preferred_uri
      else
        printf 'Multiple USB printers were detected:\n' >&2
        for detected_uri in "$@"; do
          printf '  %s\n' "$detected_uri" >&2
        done
        fail "choose one explicitly: sudo ocom-t4201-setup --uri 'usb://...'"
      fi
      ;;
  esac
fi

case "$uri" in
  usb://*) ;;
  *) fail "URI must begin with usb://" ;;
esac

printf 'Configuring queue %s\n' "$queue"
printf 'Using printer URI %s\n' "$uri"

lpadmin -p "$queue" -E -v "$uri" -P "$ppd_path"
lpadmin -p "$queue" \
  -o "PageSize=$page_size" \
  -o "MediaMethod=$method" \
  -o "PaperType=$paper_type" \
  -o "GapsHeight=$gap_mm" \
  -o "PrintSpeed=$speed" \
  -o "Darkness=$darkness"

cupsenable "$queue"
cupsaccept "$queue"

printf '\nInstalled queue defaults:\n'
lpoptions -p "$queue"
