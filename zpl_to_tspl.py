#!/usr/bin/env python3
"""
Translate a practical subset of Zebra Programming Language (ZPL II) to TSPL2.

The OCOM OCBP-T4201 is a TSPL printer. This filter accepts common ZPL label
templates on the Linux host and emits native TSPL2 for the printer.

Supported ZPL commands:
  ^XA ^XZ ^PW ^LL ^LH ^LS ^LT ^FO ^FT ^FW ^A* ^CF ^FD ^FH ^FS
  ^BY ^BC ^B3 ^BQ ^GB ^GC ^GF(A, uncompressed) ^PQ ^PR ^MD ^SD
  ^PO ^FX

Unsupported commands are ignored. Commands that could materially remove
content, such as compressed graphics or recalled/downloaded objects, produce
warnings on stderr when the program is used as a filter.
"""

from __future__ import annotations

import dataclasses
import math
import re
import shlex
import sys
from pathlib import Path
from typing import Optional

MAX_INPUT_BYTES = 16 * 1024 * 1024
MAX_OUTPUT_BYTES = 64 * 1024 * 1024
DEFAULT_DPI = 203

COMMAND_PATTERN = re.compile(r"([\^~][A-Za-z0-9@]{2})([^\^~]*)", re.DOTALL)

PAGE_SIZES = {
    "w288h108": (101.6, 38.1, 812, 305),
    "w144h288": (50.8, 101.6, 406, 812),
    "w144h360": (50.8, 127.0, 406, 1015),
    "w216h288": (76.2, 101.6, 609, 812),
    "w216h432": (76.2, 152.4, 609, 1218),
    "w288h288": (101.6, 101.6, 812, 812),
    "w288h432": (101.6, 152.4, 812, 1218),
}

ROTATIONS = {"N": 0, "R": 90, "I": 180, "B": 270}

# TSPL bitmap font metrics in dots: font name -> (width, height).
# The OCBP-T4201 identifies as TSPL rather than TSPL2, so do not rely on the
# scalable TSPL2-only font 0 or ROMAN.TTF.
TSPL_BITMAP_FONTS = {
    "1": (8, 12),
    "2": (12, 20),
    "3": (16, 24),
    "4": (24, 32),
    "5": (32, 48),
}


def _bounded_int(
    value: object,
    default: int,
    minimum: int,
    maximum: int,
) -> int:
    try:
        parsed = int(str(value).strip())
    except (TypeError, ValueError):
        return default
    return max(minimum, min(maximum, parsed))


def _select_tspl_bitmap_font(
    target_width: int,
    target_height: int,
) -> tuple[str, int, int, int, int]:
    """Choose the closest TSPL bitmap font without visibly stretching text."""
    best: Optional[tuple[float, int, str, int, int, int, int]] = None

    for font_name, (base_width, base_height) in TSPL_BITMAP_FONTS.items():
        for x_multiplier in range(1, 11):
            for y_multiplier in range(1, 11):
                actual_width = base_width * x_multiplier
                actual_height = base_height * y_multiplier
                size_error = (
                    abs(actual_width - target_width) / target_width
                    + abs(actual_height - target_height) / target_height
                )
                aspect_error = abs(
                    math.log(
                        (actual_width / actual_height)
                        / (target_width / target_height)
                    )
                )
                overshoot = (
                    max(0, actual_width - target_width) / target_width
                    + max(0, actual_height - target_height) / target_height
                )
                scaling_penalty = 0.12 * (
                    (x_multiplier - 1) + (y_multiplier - 1)
                )
                score = (
                    size_error
                    + 0.75 * aspect_error
                    + 0.25 * overshoot
                    + scaling_penalty
                )
                candidate = (
                    score,
                    -(base_width * base_height),
                    font_name,
                    x_multiplier,
                    y_multiplier,
                    actual_width,
                    actual_height,
                )
                if best is None or candidate < best:
                    best = candidate

    assert best is not None
    return best[2], best[3], best[4], best[5], best[6]


def _option_map(option_string: str) -> dict[str, str]:
    options: dict[str, str] = {}
    try:
        words = shlex.split(option_string)
    except ValueError:
        words = option_string.split()
    for word in words:
        if "=" in word:
            name, value = word.split("=", 1)
            options[name.lower()] = value
    return options


@dataclasses.dataclass
class Settings:
    width_mm: float = 101.6
    height_mm: float = 38.1
    width_dots: int = 812
    height_dots: int = 305
    dpi: int = DEFAULT_DPI
    gap_mm: int = 3
    speed: int = 5
    darkness: int = 8
    ribbon: bool = False
    media_type: str = "LabelGaps"
    copies: int = 1

    @classmethod
    def from_cups_options(
        cls,
        option_string: str = "",
        requested_copies: int = 1,
    ) -> "Settings":
        options = _option_map(option_string)
        page_size = options.get("pagesize", options.get("media", "w288h108"))
        width_mm, height_mm, width_dots, height_dots = PAGE_SIZES.get(
            page_size,
            PAGE_SIZES["w288h108"],
        )
        return cls(
            width_mm=width_mm,
            height_mm=height_mm,
            width_dots=width_dots,
            height_dots=height_dots,
            gap_mm=_bounded_int(options.get("gapsheight"), 3, 0, 10),
            speed=_bounded_int(options.get("printspeed"), 5, 2, 6),
            darkness=_bounded_int(options.get("darkness"), 8, 0, 15),
            ribbon=options.get("mediamethod", "Direct").lower() != "direct",
            media_type=options.get("papertype", "LabelGaps"),
            copies=_bounded_int(requested_copies, 1, 1, 999),
        )


@dataclasses.dataclass
class TranslationResult:
    data: bytes
    pages: int
    warnings: list[str]


@dataclasses.dataclass
class Barcode:
    kind: str
    rotation: int
    height: int
    human_readable: bool = False
    qr_cell: int = 5


class Label:
    def __init__(self, settings: Settings, warnings: list[str]) -> None:
        self.settings = dataclasses.replace(settings)
        self.warnings = warnings
        self.commands: list[bytes] = []
        self.x = 0
        self.y = 0
        self.home_x = 0
        self.home_y = 0
        self.shift_x = 0
        self.top_offset = 0
        self.field_is_typeset = False
        self.font_orientation = "N"
        self.font_height = 30
        self.font_width = 20
        self.default_orientation = "N"
        self.module_width = 2
        self.barcode_height = 100
        self.pending_barcode: Optional[Barcode] = None
        self.field_data: Optional[str] = None
        self.hex_indicator: Optional[str] = None
        self.copies = settings.copies
        self.direction = 0
        self.zpl_width_dots = settings.width_dots
        self.zpl_height_dots = settings.height_dots

    @property
    def field_x(self) -> int:
        return max(0, self.home_x + self.shift_x + self.x)

    @property
    def field_y(self) -> int:
        return max(0, self.home_y + self.top_offset + self.y)

    def add_text_command(self, command: str) -> None:
        self.commands.append(command.encode("latin-1", "replace") + b"\r\n")

    def warn(self, message: str) -> None:
        if message not in self.warnings:
            self.warnings.append(message)

    def set_origin(self, value: str, typeset: bool = False) -> None:
        parts = value.strip().split(",")
        self.x = _bounded_int(parts[0] if parts else None, 0, -100000, 100000)
        self.y = _bounded_int(
            parts[1] if len(parts) > 1 else None,
            0,
            -100000,
            100000,
        )
        self.field_is_typeset = typeset

    def set_font(self, command: str, value: str) -> None:
        parts = value.strip().split(",")
        orientation = parts[0].strip().upper() if parts else ""
        if orientation not in ROTATIONS:
            orientation = self.default_orientation
        self.font_orientation = orientation
        self.font_height = _bounded_int(
            parts[1] if len(parts) > 1 else None,
            self.font_height,
            1,
            1000,
        )
        self.font_width = _bounded_int(
            parts[2] if len(parts) > 2 else None,
            self.font_width,
            1,
            1000,
        )
        if command == "^A@":
            self.warn("^A@ downloaded fonts are mapped to a TSPL bitmap font")

    def set_default_font(self, value: str) -> None:
        parts = value.strip().split(",")
        self.font_height = _bounded_int(
            parts[1] if len(parts) > 1 else None,
            self.font_height,
            1,
            1000,
        )
        self.font_width = _bounded_int(
            parts[2] if len(parts) > 2 else None,
            self.font_width,
            1,
            1000,
        )

    def decode_field_data(self, value: str) -> str:
        data = value.rstrip("\r\n")
        if self.hex_indicator:
            indicator = re.escape(self.hex_indicator)

            def replace_hex(match: re.Match[str]) -> str:
                return chr(int(match.group(1), 16))

            data = re.sub(
                indicator + r"([0-9A-Fa-f]{2})",
                replace_hex,
                data,
            )
        return data

    @staticmethod
    def safe_string(value: str) -> str:
        return (
            value.replace("\x00", "")
            .replace("\r", " ")
            .replace("\n", " ")
            .replace('"', "'")
        )

    def flush_field(self) -> None:
        if self.field_data is None:
            self.pending_barcode = None
            self.hex_indicator = None
            return

        value = self.safe_string(self.decode_field_data(self.field_data))
        x = self.field_x
        y = self.field_y

        if self.pending_barcode is None:
            rotation = ROTATIONS.get(self.font_orientation, 0)
            (
                font_name,
                x_multiplier,
                y_multiplier,
                _actual_width,
                actual_height,
            ) = _select_tspl_bitmap_font(self.font_width, self.font_height)
            if self.field_is_typeset and rotation in (0, 180):
                y = max(0, y - actual_height)
            self.add_text_command(
                f'TEXT {x},{y},"{font_name}",{rotation},{x_multiplier},'
                f'{y_multiplier},"{value}"'
            )
        elif self.pending_barcode.kind == "QRCODE":
            qr_data = value
            if len(qr_data) >= 3 and qr_data[1:3] == "A,":
                qr_data = qr_data[3:]
            self.add_text_command(
                f'QRCODE {x},{y},L,{self.pending_barcode.qr_cell},A,'
                f'{self.pending_barcode.rotation},M2,S7,"{qr_data}"'
            )
        else:
            readable = 1 if self.pending_barcode.human_readable else 0
            height = self.pending_barcode.height
            if self.pending_barcode.rotation in (0, 180):
                available_height = self.settings.height_dots - y
                if available_height < height:
                    height = max(1, available_height)
                    self.warn(
                        "barcode height was clipped to the physical label boundary"
                    )
            self.add_text_command(
                f'BARCODE {x},{y},"{self.pending_barcode.kind}",'
                f'{height},{readable},'
                f'{self.pending_barcode.rotation},{self.module_width},'
                f'{self.module_width},"{value}"'
            )

        self.field_data = None
        self.pending_barcode = None
        self.hex_indicator = None
        self.field_is_typeset = False

    def add_box(self, value: str) -> None:
        parts = value.strip().split(",")
        width = _bounded_int(parts[0] if parts else None, 1, 1, 100000)
        height = _bounded_int(
            parts[1] if len(parts) > 1 else None,
            1,
            1,
            100000,
        )
        thickness = _bounded_int(
            parts[2] if len(parts) > 2 else None,
            1,
            1,
            min(width, height),
        )
        color = parts[3].strip().upper() if len(parts) > 3 else "B"
        if color == "W":
            self.add_text_command(
                f"ERASE {self.field_x},{self.field_y},{width},{height}"
            )
        elif width <= thickness or height <= thickness:
            self.add_text_command(
                f"BAR {self.field_x},{self.field_y},{width},{height}"
            )
        else:
            self.add_text_command(
                f"BOX {self.field_x},{self.field_y},"
                f"{self.field_x + width},{self.field_y + height},{thickness}"
            )

    def add_circle(self, value: str) -> None:
        parts = value.strip().split(",")
        diameter = _bounded_int(parts[0] if parts else None, 3, 1, 100000)
        thickness = _bounded_int(
            parts[1] if len(parts) > 1 else None,
            1,
            1,
            diameter,
        )
        self.add_text_command(
            f"CIRCLE {self.field_x},{self.field_y},{diameter},{thickness}"
        )

    def add_graphic_field(self, value: str) -> None:
        parts = value.strip().split(",", 4)
        if len(parts) != 5 or parts[0].strip().upper() != "A":
            self.warn("only uncompressed ASCII ^GFA graphics are supported")
            return

        bytes_per_row = _bounded_int(parts[3], 0, 1, 1024 * 1024)
        hexadecimal = re.sub(r"\s+", "", parts[4])
        if not hexadecimal or re.search(r"[^0-9A-Fa-f]", hexadecimal):
            self.warn("compressed or malformed ^GFA graphic was skipped")
            return
        if len(hexadecimal) % 2 != 0:
            self.warn("odd-length ^GFA hexadecimal data was skipped")
            return

        try:
            zpl_bitmap = bytes.fromhex(hexadecimal)
        except ValueError:
            self.warn("malformed ^GFA hexadecimal data was skipped")
            return

        declared_bytes = _bounded_int(parts[2], len(zpl_bitmap), 1, MAX_INPUT_BYTES)
        if len(zpl_bitmap) < declared_bytes:
            self.warn("short ^GFA graphic data was skipped")
            return
        zpl_bitmap = zpl_bitmap[:declared_bytes]

        remainder = len(zpl_bitmap) % bytes_per_row
        if remainder:
            zpl_bitmap += b"\x00" * (bytes_per_row - remainder)
        height = len(zpl_bitmap) // bytes_per_row

        # ZPL uses set bits for black; the OCBP TSPL bitmap uses cleared bits.
        tspl_bitmap = bytes(byte ^ 0xFF for byte in zpl_bitmap)
        header = (
            f"BITMAP {self.field_x},{self.field_y},{bytes_per_row},"
            f"{height},0,"
        ).encode("ascii")
        self.commands.append(header + tspl_bitmap + b"\r\n")

    def apply_command(self, command: str, raw_value: str) -> None:
        value = raw_value.strip("\r\n")
        upper = command.upper()

        if upper == "^PW":
            dots = _bounded_int(value, self.settings.width_dots, 1, 100000)
            self.zpl_width_dots = dots
            if dots != self.settings.width_dots:
                self.warn(
                    f"^PW{dots} differs from the CUPS media width "
                    f"{self.settings.width_dots}; kept the physical media size"
                )
        elif upper == "^LL":
            dots = _bounded_int(value, self.settings.height_dots, 1, 100000)
            self.zpl_height_dots = dots
            if dots != self.settings.height_dots:
                self.warn(
                    f"^LL{dots} differs from the CUPS media height "
                    f"{self.settings.height_dots}; kept the physical media size"
                )
        elif upper == "^LH":
            parts = value.split(",")
            self.home_x = _bounded_int(parts[0] if parts else None, 0, -100000, 100000)
            self.home_y = _bounded_int(
                parts[1] if len(parts) > 1 else None,
                0,
                -100000,
                100000,
            )
        elif upper == "^LS":
            self.shift_x = _bounded_int(value, 0, -100000, 100000)
        elif upper == "^LT":
            self.top_offset = _bounded_int(value, 0, -100000, 100000)
        elif upper == "^FO":
            self.set_origin(value, False)
        elif upper == "^FT":
            self.set_origin(value, True)
        elif upper == "^FW":
            orientation = value.split(",", 1)[0].strip().upper()
            if orientation in ROTATIONS:
                self.default_orientation = orientation
                self.font_orientation = orientation
        elif upper.startswith("^A"):
            self.set_font(upper, value)
        elif upper == "^CF":
            self.set_default_font(value)
        elif upper == "^FH":
            indicator = value.strip()
            self.hex_indicator = indicator[0] if indicator else "_"
        elif upper == "^FD":
            self.field_data = raw_value.rstrip("\r\n")
        elif upper == "^FS":
            self.flush_field()
        elif upper == "^BY":
            parts = value.split(",")
            self.module_width = _bounded_int(
                parts[0] if parts else None,
                2,
                1,
                10,
            )
            self.barcode_height = _bounded_int(
                parts[2] if len(parts) > 2 else None,
                self.barcode_height,
                1,
                10000,
            )
        elif upper == "^BC":
            parts = value.split(",")
            orientation = parts[0].strip().upper() if parts else "N"
            height = _bounded_int(
                parts[1] if len(parts) > 1 else None,
                self.barcode_height,
                1,
                10000,
            )
            readable = (
                len(parts) > 2 and parts[2].strip().upper().startswith("Y")
            )
            self.pending_barcode = Barcode(
                "128",
                ROTATIONS.get(orientation, 0),
                height,
                readable,
            )
        elif upper == "^B3":
            parts = value.split(",")
            orientation = parts[0].strip().upper() if parts else "N"
            height = _bounded_int(
                parts[2] if len(parts) > 2 else None,
                self.barcode_height,
                1,
                10000,
            )
            readable = (
                len(parts) > 3 and parts[3].strip().upper().startswith("Y")
            )
            self.pending_barcode = Barcode(
                "39",
                ROTATIONS.get(orientation, 0),
                height,
                readable,
            )
        elif upper == "^BQ":
            parts = value.split(",")
            orientation = parts[0].strip().upper() if parts else "N"
            cell = _bounded_int(
                parts[2] if len(parts) > 2 else None,
                5,
                1,
                10,
            )
            self.pending_barcode = Barcode(
                "QRCODE",
                ROTATIONS.get(orientation, 0),
                0,
                False,
                cell,
            )
        elif upper == "^GB":
            self.add_box(value)
        elif upper == "^GC":
            self.add_circle(value)
        elif upper == "^GF":
            self.add_graphic_field(raw_value)
        elif upper == "^PQ":
            parts = value.split(",")
            self.copies = _bounded_int(
                parts[0] if parts else None,
                self.copies,
                1,
                999,
            )
        elif upper == "^PR":
            speed_value = value.split(",", 1)[0].strip().upper()
            letter_speeds = {"A": 2, "B": 3, "C": 4, "D": 5, "E": 6, "F": 6}
            self.settings.speed = letter_speeds.get(
                speed_value,
                _bounded_int(speed_value, self.settings.speed, 2, 6),
            )
        elif upper == "^MD":
            relative = _bounded_int(value, 0, -30, 30)
            self.settings.darkness = max(
                0,
                min(15, self.settings.darkness + int(round(relative / 4.0))),
            )
        elif upper in {"^SD", "~SD"}:
            zpl_darkness = _bounded_int(value, 16, 0, 30)
            self.settings.darkness = max(
                0,
                min(15, int(round(zpl_darkness / 2.0))),
            )
        elif upper == "^PO":
            self.direction = 1 if value.strip().upper().startswith("I") else 0
        elif upper in {
            "^CI",
            "^FX",
            "^MM",
            "^MN",
            "^MT",
            "^JU",
            "^JZ",
        }:
            return
        elif upper in {"^FB", "^FP", "^FR", "^LR", "^PM", "^SN"}:
            self.warn(f"{upper} formatting is not supported and was ignored")
        elif upper in {"^XG", "~DG", "^DF", "^XF"}:
            self.warn(f"{upper} stored/recalled objects are not supported")
        else:
            self.warn(f"{upper} is not supported and was ignored")

    def render(self) -> bytes:
        self.flush_field()
        settings = self.settings
        output: list[bytes] = [
            f"SIZE {settings.width_mm:.1f} mm,{settings.height_mm:.1f} mm\r\n".encode(),
        ]
        if settings.media_type.lower() == "labelmark":
            output.append(f"BLINE {settings.gap_mm}.0 mm,0.0 mm\r\n".encode())
        elif settings.media_type.lower() == "continue":
            output.append(b"GAP 0.0 mm,0.0 mm\r\n")
        else:
            output.append(f"GAP {settings.gap_mm}.0 mm,0.0 mm\r\n".encode())
        output.extend(
            [
                f"SPEED {settings.speed}\r\n".encode(),
                f"DENSITY {settings.darkness}\r\n".encode(),
                f"SET RIBBON {'ON' if settings.ribbon else 'OFF'}\r\n".encode(),
                f"DIRECTION {self.direction},0\r\n".encode(),
                b"REFERENCE 0,0\r\n",
                b"OFFSET 0.0 mm\r\n",
                b"SET TEAR ON\r\n",
                b"SET PEEL OFF\r\n",
                b"SET CUTTER OFF\r\n",
                b"CLS\r\n",
            ]
        )
        output.extend(self.commands)
        output.append(f"PRINT 1,{self.copies}\r\n".encode())
        return b"".join(output)


def translate_zpl(source: bytes, settings: Optional[Settings] = None) -> TranslationResult:
    if len(source) > MAX_INPUT_BYTES:
        raise ValueError(f"ZPL input exceeds {MAX_INPUT_BYTES} bytes")

    base_settings = settings or Settings()
    text = source.decode("latin-1")
    warnings: list[str] = []
    output: list[bytes] = []
    output_size = 0
    current: Optional[Label] = None
    pages = 0

    for match in COMMAND_PATTERN.finditer(text):
        command = match.group(1).upper()
        value = match.group(2)

        if command == "^XA":
            if current is not None:
                warnings.append("nested ^XA closed the previous label")
                rendered = current.render()
                output.append(rendered)
                output_size += len(rendered)
                pages += 1
            current = Label(base_settings, warnings)
        elif command == "^XZ":
            if current is not None:
                rendered = current.render()
                output.append(rendered)
                output_size += len(rendered)
                pages += 1
                current = None
        elif current is not None:
            current.apply_command(command, value)

        if output_size > MAX_OUTPUT_BYTES:
            raise ValueError(f"translated output exceeds {MAX_OUTPUT_BYTES} bytes")

    if current is not None:
        warnings.append("missing ^XZ; the final label was closed automatically")
        rendered = current.render()
        output.append(rendered)
        output_size += len(rendered)
        pages += 1

    if pages == 0:
        raise ValueError("ZPL input contains no ^XA ... ^XZ label")

    data = b"".join(output)
    if len(data) > MAX_OUTPUT_BYTES:
        raise ValueError(f"translated output exceeds {MAX_OUTPUT_BYTES} bytes")
    return TranslationResult(data=data, pages=pages, warnings=warnings)


def _read_input(arguments: list[str]) -> tuple[bytes, Settings]:
    if len(arguments) == 1:
        data = sys.stdin.buffer.read(MAX_INPUT_BYTES + 1)
        settings = Settings()
    elif len(arguments) == 2:
        data = Path(arguments[1]).read_bytes()
        settings = Settings()
    elif len(arguments) in (6, 7):
        requested_copies = _bounded_int(arguments[4], 1, 1, 999)
        settings = Settings.from_cups_options(arguments[5], requested_copies)
        if len(arguments) == 7:
            data = Path(arguments[6]).read_bytes()
        else:
            data = sys.stdin.buffer.read(MAX_INPUT_BYTES + 1)
    else:
        raise ValueError(
            "usage: zpl_to_tspl job-id user title copies options [file]"
        )

    if len(data) > MAX_INPUT_BYTES:
        raise ValueError(f"ZPL input exceeds {MAX_INPUT_BYTES} bytes")
    return data, settings


def main(arguments: Optional[list[str]] = None) -> int:
    argv = arguments or sys.argv
    try:
        source, settings = _read_input(argv)
        result = translate_zpl(source, settings)
        for warning in result.warnings:
            print(f"WARNING: {warning}", file=sys.stderr)
        for page in range(1, result.pages + 1):
            print(f"PAGE: {page} 1", file=sys.stderr)
        sys.stdout.buffer.write(result.data)
        sys.stdout.buffer.flush()
        return 0
    except BrokenPipeError:
        return 1
    except (OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
