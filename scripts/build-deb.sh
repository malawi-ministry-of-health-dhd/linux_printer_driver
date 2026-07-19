#!/bin/sh

set -eu

package_name=ocom-ocbp-t4201-driver
version=${VERSION:-1.0.4}
project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_dir=${BUILD_DIR:-"$project_root/build/deb"}
dist_dir=${DIST_DIR:-"$project_root/dist"}

fail()
{
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

[ "$(uname -s)" = Linux ] ||
  fail "Debian packages must contain a Linux binary; run 'make deb-docker' from macOS"

for command_name in dpkg dpkg-deb install sed du md5sum; do
  command -v "$command_name" >/dev/null 2>&1 ||
    fail "required package-build command not found: $command_name"
done

case "$version" in
  *[!A-Za-z0-9.+:~-]*|'') fail "invalid Debian VERSION: $version" ;;
esac

architecture=${DEB_ARCH:-$(dpkg --print-architecture)}
case "$architecture" in
  *[!a-z0-9-]*|'') fail "invalid Debian architecture: $architecture" ;;
esac

raster_filter="$project_root/raster_to_tspl"
[ -x "$raster_filter" ] ||
  fail "Linux raster filter is missing; run make before packaging"

package_root="$build_dir/root"
if [ -e "$package_root" ]; then
  find "$package_root" -depth -delete
fi

install -d \
  "$package_root/DEBIAN" \
  "$package_root/etc/default" \
  "$package_root/usr/lib/cups/filter" \
  "$package_root/usr/lib/ocom-t4201" \
  "$package_root/usr/sbin" \
  "$package_root/usr/share/cups/mime" \
  "$package_root/usr/share/doc/$package_name" \
  "$package_root/usr/share/ocom-t4201" \
  "$package_root/usr/share/ppd/ocom"

install -m 0755 \
  "$raster_filter" \
  "$package_root/usr/lib/cups/filter/raster_to_tspl"
install -m 0755 \
  "$project_root/zpl_to_tspl.py" \
  "$package_root/usr/lib/cups/filter/zpl_to_tspl"
install -m 0755 \
  "$project_root/scripts/configure-printer.sh" \
  "$package_root/usr/lib/ocom-t4201/configure-printer.sh"
install -m 0755 \
  "$project_root/scripts/print-sample.sh" \
  "$package_root/usr/lib/ocom-t4201/print-sample.sh"
install -m 0755 \
  "$project_root/scripts/ocom-t4201-setup" \
  "$package_root/usr/sbin/ocom-t4201-setup"

install -m 0644 \
  "$project_root/OCOM_T4201_Linux.ppd" \
  "$package_root/usr/share/ppd/ocom/OCOM_T4201_Linux.ppd"
install -m 0644 \
  "$project_root/mime/ocom-zpl.types" \
  "$package_root/usr/share/cups/mime/ocom-zpl.types"
install -m 0644 \
  "$project_root/mime/ocom-zpl.convs" \
  "$package_root/usr/share/cups/mime/ocom-zpl.convs"
install -m 0644 \
  "$project_root/tests/OCOM_T4201_test_label.zpl" \
  "$package_root/usr/share/ocom-t4201/OCOM_T4201_test_label.zpl"
install -m 0644 \
  "$project_root/tests/OCOM_T4201_test_commands.tspl" \
  "$package_root/usr/share/ocom-t4201/OCOM_T4201_test_commands.tspl"
install -m 0644 \
  "$project_root/tests/OCOM_T4201_test_label.pdf" \
  "$package_root/usr/share/ocom-t4201/OCOM_T4201_test_label.pdf"
install -m 0644 \
  "$project_root/README.md" \
  "$package_root/usr/share/doc/$package_name/README.md"
install -m 0644 \
  "$project_root/packaging/debian/copyright" \
  "$package_root/usr/share/doc/$package_name/copyright"
install -m 0644 \
  "$project_root/packaging/debian/ocom-t4201-driver.default" \
  "$package_root/etc/default/ocom-t4201-driver"

install -m 0755 \
  "$project_root/packaging/debian/postinst" \
  "$package_root/DEBIAN/postinst"
install -m 0755 \
  "$project_root/packaging/debian/postrm" \
  "$package_root/DEBIAN/postrm"
printf '%s\n' '/etc/default/ocom-t4201-driver' \
  > "$package_root/DEBIAN/conffiles"

installed_size=$(du -sk "$package_root" | awk '{ print $1 }')
sed \
  -e "s/@VERSION@/$version/g" \
  -e "s/@ARCH@/$architecture/g" \
  -e "s/@INSTALLED_SIZE@/$installed_size/g" \
  "$project_root/packaging/debian/control.in" \
  > "$package_root/DEBIAN/control"

(
  cd "$package_root"
  find . -path './DEBIAN' -prune -o -type f -print |
    LC_ALL=C sort |
    while IFS= read -r packaged_file; do
      md5sum "${packaged_file#./}"
    done
) > "$package_root/DEBIAN/md5sums"

install -d "$dist_dir"
output="$dist_dir/${package_name}_${version}_${architecture}.deb"
dpkg-deb --root-owner-group -Zxz --build "$package_root" "$output"

printf 'Built Debian package:\n  %s\n' "$output"
dpkg-deb --info "$output"
