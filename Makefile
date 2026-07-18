SHELL := /bin/sh

CC ?= gcc
NODE ?= node
PYTHON ?= python3
CUPS_CONFIG ?= cups-config
CFLAGS ?= -O2
CPPFLAGS += $(shell $(CUPS_CONFIG) --cflags)
CFLAGS += -Wall -Wextra -Wpedantic
LDLIBS += $(shell $(CUPS_CONFIG) --libs) -lcupsimage

QUEUE ?= OCOM_Ubuntu_Driver
URI ?=
METHOD ?= Direct
PAGE_SIZE ?= w288h108
PAPER_TYPE ?= LabelGaps
GAP_MM ?= 3
SPEED ?= 5
DARKNESS ?= 8
SETUP_TEST ?= zpl
INPUT ?= tests/OCOM_T4201_test_label.zpl
OUTPUT ?= /tmp/OCOM_T4201_translated.tspl
VERSION ?= 1.0.0
DEB_PLATFORM ?= linux/amd64
DEB_IMAGE ?= ubuntu:22.04

CUPS_SERVERBIN ?= $(shell $(CUPS_CONFIG) --serverbin 2>/dev/null || printf '%s' /usr/lib/cups)
FILTER_DIR ?= $(CUPS_SERVERBIN)/filter
PPD_DIR ?= /usr/share/ppd
MIME_DIR ?= /usr/share/cups/mime
PPD_PATH := $(abspath OCOM_T4201_Linux.ppd)
TEST_RASTER_GENERATOR := $(abspath tests/generate_test_raster)
SAMPLE_PDF := $(abspath tests/OCOM_T4201_test_label.pdf)
SAMPLE_TSPL := $(abspath tests/OCOM_T4201_test_commands.tspl)
SAMPLE_ZPL := $(abspath tests/OCOM_T4201_test_label.zpl)
ZPL_TRANSLATOR := $(abspath zpl_to_tspl.py)

.NOTPARALLEL:
.PHONY: all check clean configure deb deb-docker help install package-version sample-pdf restart-cups setup test-pdf test-printer test-tspl test-zpl translate-zpl

all: raster_to_tspl

raster_to_tspl: raster_to_tspl.c
	$(CC) $(CPPFLAGS) $(CFLAGS) $< -o $@ $(LDFLAGS) $(LDLIBS)

tests/generate_test_raster: tests/generate_test_raster.c
	$(CC) $(CPPFLAGS) $(CFLAGS) $< -o $@ $(LDFLAGS) $(LDLIBS)

check: raster_to_tspl tests/generate_test_raster
	./raster_to_tspl </dev/null 2>/dev/null; test $$? -eq 1
	./tests/generate_test_raster | ./raster_to_tspl >/dev/null
	$(PYTHON) -m unittest tests/test_zpl_translator.py
	sh -n scripts/*.sh scripts/ocom-t4201-setup packaging/debian/postinst packaging/debian/postrm
	./tests/test_auto_setup.sh
	cupstestppd -q -I filters OCOM_T4201_Linux.ppd

deb: check
	VERSION="$(VERSION)" ./scripts/build-deb.sh

deb-docker:
	VERSION="$(VERSION)" DEB_PLATFORM="$(DEB_PLATFORM)" DEB_IMAGE="$(DEB_IMAGE)" \
	./scripts/build-deb-docker.sh

package-version:
	@printf '%s\n' "$(VERSION)"

install: raster_to_tspl zpl_to_tspl.py OCOM_T4201_Linux.ppd mime/ocom-zpl.types mime/ocom-zpl.convs
	install -d -o root -g root -m 0755 "$(FILTER_DIR)" "$(PPD_DIR)" "$(MIME_DIR)"
	install -o root -g root -m 0755 raster_to_tspl "$(FILTER_DIR)/raster_to_tspl"
	install -o root -g root -m 0755 zpl_to_tspl.py "$(FILTER_DIR)/zpl_to_tspl"
	install -o root -g root -m 0644 OCOM_T4201_Linux.ppd "$(PPD_DIR)/OCOM_T4201_Linux.ppd"
	install -o root -g root -m 0644 mime/ocom-zpl.types "$(MIME_DIR)/ocom-zpl.types"
	install -o root -g root -m 0644 mime/ocom-zpl.convs "$(MIME_DIR)/ocom-zpl.convs"

restart-cups:
	@if command -v systemctl >/dev/null 2>&1; then \
		systemctl enable --now cups; \
		systemctl restart cups; \
	elif command -v service >/dev/null 2>&1; then \
		service cups restart; \
	else \
		echo "ERROR: unable to find systemctl or service" >&2; \
		exit 1; \
	fi

configure:
	QUEUE="$(QUEUE)" URI="$(URI)" METHOD="$(METHOD)" \
	PAGE_SIZE="$(PAGE_SIZE)" PAPER_TYPE="$(PAPER_TYPE)" GAP_MM="$(GAP_MM)" \
	SPEED="$(SPEED)" DARKNESS="$(DARKNESS)" PPD_PATH="$(PPD_PATH)" \
	./scripts/configure-printer.sh

setup: all check install restart-cups configure
	@echo "Configured CUPS queue: $(QUEUE)"
	@case "$(SETUP_TEST)" in \
	  zpl) \
	    echo "Printing the ZPL-to-TSPL test label..."; \
	    $(MAKE) --no-print-directory test-zpl ;; \
	  none) \
	    echo "Skipping the physical test print (SETUP_TEST=none)." ;; \
	  *) \
	    echo "ERROR: SETUP_TEST must be zpl or none" >&2; \
	    exit 1 ;; \
	esac

test-printer: tests/generate_test_raster
	QUEUE="$(QUEUE)" METHOD="$(METHOD)" PAGE_SIZE="$(PAGE_SIZE)" \
	PAPER_TYPE="$(PAPER_TYPE)" GAP_MM="$(GAP_MM)" SPEED="$(SPEED)" \
	DARKNESS="$(DARKNESS)" FILTER_PATH="$(FILTER_DIR)/raster_to_tspl" \
	RASTER_GENERATOR="$(TEST_RASTER_GENERATOR)" ./scripts/test-printer.sh

sample-pdf:
	$(NODE) scripts/generate-test-pdf.js "$(SAMPLE_PDF)"

test-pdf:
	QUEUE="$(QUEUE)" METHOD="$(METHOD)" PAGE_SIZE="$(PAGE_SIZE)" \
	PAPER_TYPE="$(PAPER_TYPE)" GAP_MM="$(GAP_MM)" SPEED="$(SPEED)" \
	DARKNESS="$(DARKNESS)" SAMPLE_FILE="$(SAMPLE_PDF)" \
	./scripts/print-sample.sh pdf

test-tspl:
	QUEUE="$(QUEUE)" METHOD="$(METHOD)" GAP_MM="$(GAP_MM)" \
	SPEED="$(SPEED)" DARKNESS="$(DARKNESS)" SAMPLE_FILE="$(SAMPLE_TSPL)" \
	./scripts/print-sample.sh tspl

test-zpl:
	QUEUE="$(QUEUE)" METHOD="$(METHOD)" PAGE_SIZE="$(PAGE_SIZE)" \
	PAPER_TYPE="$(PAPER_TYPE)" GAP_MM="$(GAP_MM)" SPEED="$(SPEED)" \
	DARKNESS="$(DARKNESS)" SAMPLE_FILE="$(SAMPLE_ZPL)" \
	TRANSLATOR_PATH="$(FILTER_DIR)/zpl_to_tspl" \
	./scripts/print-sample.sh zpl

translate-zpl:
	@test -r "$(INPUT)" || { echo "ERROR: cannot read INPUT=$(INPUT)" >&2; exit 1; }
	$(PYTHON) zpl_to_tspl.py "$(INPUT)" > "$(OUTPUT)"
	@echo "Translated $(INPUT) -> $(OUTPUT)"

help:
	@echo "make                         Build the raster_to_tspl filter"
	@echo "make deb                     Build a .deb on Debian/Ubuntu"
	@echo "make deb-docker              Build an amd64 .deb using Docker"
	@echo "sudo make setup              Install/configure, then print the sample ZPL label"
	@echo "sudo make setup SETUP_TEST=none  Install/configure without physical printing"
	@echo "make test-printer            Test raster filter and USB connection"
	@echo "make test-pdf                Print the sample PDF through the driver"
	@echo "make test-tspl               Send readable TSPL2 commands directly"
	@echo "make test-zpl                Translate and print the sample ZPL"
	@echo "make translate-zpl INPUT=... OUTPUT=...  Translate ZPL without printing"
	@echo "make sample-pdf              Regenerate the sample PDF using Node.js"
	@echo "sudo make configure URI=...  Configure using an explicit USB URI"
	@echo
	@echo "Overrides: QUEUE, URI, METHOD, PAGE_SIZE, PAPER_TYPE, GAP_MM, SPEED, DARKNESS, SETUP_TEST"

clean:
	rm -f raster_to_tspl tests/generate_test_raster
