#!/usr/bin/env node

/*
 * Generate the repository's 4x1.5-inch PDF test label without third-party
 * dependencies. Usage:
 *
 *   node scripts/generate-test-pdf.js tests/OCOM_T4201_test_label.pdf
 */

"use strict";

const fs = require("fs");
const path = require("path");

const outputPath = process.argv[2];

if (!outputPath) {
  process.stderr.write(
    "Usage: node scripts/generate-test-pdf.js output-file.pdf\n",
  );
  process.exit(1);
}

/*
 * Code 128 subset B for "JOHNDOE":
 * Start B, J, O, H, N, D, O, E, checksum 29, stop.
 */
const code128Patterns = [
  "211214",
  "112133",
  "133121",
  "231113",
  "113321",
  "112313",
  "133121",
  "132113",
  "322211",
  "2331112",
];
const moduleWidth = 2;
const totalModules = 112;
let barcodeX = (288 - totalModules * moduleWidth) / 2;
const barcodeCommands = [];

for (const pattern of code128Patterns) {
  for (let element = 0; element < pattern.length; element += 1) {
    const elementWidth = Number(pattern[element]) * moduleWidth;
    if (element % 2 === 0) {
      barcodeCommands.push(
        `${barcodeX.toFixed(1)} 42 ${elementWidth} 52 re f`,
      );
    }
    barcodeX += elementWidth;
  }
}

const content = [
  "q",
  "0 G",
  "1 g",
  "0 0 288 108 re f",
  "0 g",
  "1 w",
  "4 4 280 100 re S",
  ...barcodeCommands,
  "BT",
  "/F2 14 Tf",
  "109 18 Td",
  "(JOHN DOE) Tj",
  "ET",
  "Q",
].join("\n");

const objects = [
  "<< /Type /Catalog /Pages 2 0 R >>",
  "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
  [
    "<< /Type /Page",
    "/Parent 2 0 R",
    "/MediaBox [0 0 288 108]",
    "/CropBox [0 0 288 108]",
    "/Resources << /Font << /F1 5 0 R /F2 6 0 R >> >>",
    "/Contents 4 0 R",
    ">>",
  ].join(" "),
  `<< /Length ${Buffer.byteLength(content, "ascii")} >>\nstream\n${content}\nendstream`,
  "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
  "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold >>",
];

let pdf = "%PDF-1.4\n% OCOM test label\n";
const offsets = [0];

objects.forEach((object, index) => {
  offsets.push(Buffer.byteLength(pdf, "ascii"));
  pdf += `${index + 1} 0 obj\n${object}\nendobj\n`;
});

const xrefOffset = Buffer.byteLength(pdf, "ascii");
pdf += `xref\n0 ${objects.length + 1}\n`;
pdf += "0000000000 65535 f \n";

for (let index = 1; index < offsets.length; index += 1) {
  pdf += `${String(offsets[index]).padStart(10, "0")} 00000 n \n`;
}

pdf += [
  "trailer",
  `<< /Size ${objects.length + 1} /Root 1 0 R >>`,
  "startxref",
  String(xrefOffset),
  "%%EOF",
  "",
].join("\n");

fs.mkdirSync(path.dirname(path.resolve(outputPath)), { recursive: true });
fs.writeFileSync(outputPath, Buffer.from(pdf, "ascii"));
process.stdout.write(`Generated ${outputPath}\n`);
