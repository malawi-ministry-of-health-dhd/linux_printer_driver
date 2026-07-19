#!/usr/bin/env python3

import unittest
from pathlib import Path

from zpl_to_tspl import Settings, translate_zpl


ROOT = Path(__file__).resolve().parent.parent


class ZplToTsplTests(unittest.TestCase):
    def test_repository_sample(self) -> None:
        source = (ROOT / "tests/OCOM_T4201_test_label.zpl").read_bytes()
        result = translate_zpl(source, Settings())

        self.assertEqual(result.pages, 1)
        self.assertEqual(result.warnings, [])
        self.assertIn(b"SIZE 101.6 mm,38.1 mm\r\n", result.data)
        self.assertIn(b"BOX 8,8,803,297,3\r\n", result.data)
        self.assertIn(
            b'BARCODE 238,30,"128",130,0,0,3,3,"JOHNDOE"\r\n',
            result.data,
        )
        self.assertIn(b'TEXT 278,205,"5",0,1,1,"JOHN DOE"\r\n', result.data)
        self.assertTrue(result.data.endswith(b"PRINT 1,1\r\n"))

    def test_code39_qr_hex_text_and_copies(self) -> None:
        source = (
            b"^XA"
            b"^FO10,10^BY2,3,80^B3N,N,80,Y,N^FDABC123^FS"
            b"^FO20,120^BQN,2,4^FDLA,HELLO^FS"
            b"^FO20,220^A0N,24,16^FH^FDJOHN_20DOE^FS"
            b"^PQ3^XZ"
        )
        result = translate_zpl(source)

        self.assertIn(b'BARCODE 10,10,"39",80,1,0,2,2,"ABC123"', result.data)
        self.assertIn(b'QRCODE 20,120,L,4,A,0,M2,S7,"HELLO"', result.data)
        self.assertIn(b'TEXT 20,220,"3",0,1,1,"JOHN DOE"', result.data)
        self.assertTrue(result.data.endswith(b"PRINT 1,3\r\n"))

    def test_uncompressed_graphic_field_inverts_bitmap_polarity(self) -> None:
        source = b"^XA^FO1,2^GFA,2,2,1,80FF^XZ"
        result = translate_zpl(source)

        self.assertIn(b"BITMAP 1,2,1,2,0,\x7f\x00\r\n", result.data)

    def test_cups_media_bounds_and_square_font_for_patient_label(self) -> None:
        source = (
            b"^XA^PW750^LL450"
            b"^FO10,15^FB800,10,5,L,0"
            b"^A0N,30,30^FDJohn Banda - 1969-03-11 ^FS"
            b"^FO10,55^FB800,10,5,L,0"
            b"^A0N,30,30^FDP100100000025 (M)^FS"
            b"^FO10,90^FB800,10,5,L,0"
            b"^A0N,30,30^FDDedza, Chauma, Biwi James^FS"
            b"^FO20,130^BY4,150,8"
            b"^BCN,150,N,N,N^FDP100100000025^FS^FS^XZ"
        )
        result = translate_zpl(source, Settings())

        self.assertIn(b"SIZE 101.6 mm,38.1 mm\r\n", result.data)
        self.assertNotIn(b"SIZE 93.8 mm,56.3 mm\r\n", result.data)
        self.assertIn(
            b'TEXT 10,15,"4",0,1,1,"John Banda - 1969-03-11 "\r\n',
            result.data,
        )
        self.assertIn(
            b'BARCODE 20,130,"128",150,0,0,4,4,"P100100000025"\r\n',
            result.data,
        )
        self.assertTrue(any("^PW750" in warning for warning in result.warnings))
        self.assertTrue(any("^LL450" in warning for warning in result.warnings))

    def test_cups_options_control_setup(self) -> None:
        settings = Settings.from_cups_options(
            "PageSize=w288h108 MediaMethod=Transfer PaperType=LabelMark "
            "GapsHeight=2 PrintSpeed=4 Darkness=10",
            2,
        )
        result = translate_zpl(b"^XA^FO0,0^FDOK^FS^XZ", settings)

        self.assertIn(b"BLINE 2.0 mm,0.0 mm\r\n", result.data)
        self.assertIn(b"SPEED 4\r\n", result.data)
        self.assertIn(b"DENSITY 10\r\n", result.data)
        self.assertIn(b"SET RIBBON ON\r\n", result.data)
        self.assertTrue(result.data.endswith(b"PRINT 1,2\r\n"))

    def test_unsupported_objects_warn_and_invalid_input_fails(self) -> None:
        result = translate_zpl(b'^XA^XGLOGO.GRF,1,1^XZ')
        self.assertTrue(any("^XG" in warning for warning in result.warnings))

        with self.assertRaisesRegex(ValueError, "no \\^XA"):
            translate_zpl(b"not a label")


if __name__ == "__main__":
    unittest.main()
