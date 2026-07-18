/*
 * Generate a deterministic 4x1.5-inch, 203-dpi, one-bit CUPS raster page.
 *
 * This helper is used only by `make check` and `make test-printer`.
 */

#include <cups/raster.h>

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define TEST_DPI 203U
#define TEST_WIDTH 812U
#define TEST_HEIGHT 305U
#define TEST_BYTES_PER_LINE ((TEST_WIDTH + 7U) / 8U)

typedef struct {
  unsigned char *pixels;
  unsigned int width;
  unsigned int height;
  unsigned int bytes_per_line;
} bitmap_t;

static void
set_black(bitmap_t *bitmap, int x, int y)
{
  if (x < 0 || y < 0 || (unsigned int)x >= bitmap->width ||
      (unsigned int)y >= bitmap->height)
    return;

  bitmap->pixels[(size_t)y * bitmap->bytes_per_line + (unsigned int)x / 8U] |=
      (unsigned char)(0x80U >> ((unsigned int)x % 8U));
}

static void
filled_rectangle(bitmap_t *bitmap, int x, int y, int width, int height)
{
  int row;
  int column;

  for (row = y; row < y + height; ++row) {
    for (column = x; column < x + width; ++column)
      set_black(bitmap, column, row);
  }
}

static void
rectangle_outline(bitmap_t *bitmap, int x, int y, int width, int height,
                  int thickness)
{
  filled_rectangle(bitmap, x, y, width, thickness);
  filled_rectangle(bitmap, x, y + height - thickness, width, thickness);
  filled_rectangle(bitmap, x, y, thickness, height);
  filled_rectangle(bitmap, x + width - thickness, y, thickness, height);
}

static void
draw_glyph(bitmap_t *bitmap, int x, int y, const uint8_t rows[7], int scale)
{
  int row;
  int column;

  for (row = 0; row < 7; ++row) {
    for (column = 0; column < 5; ++column) {
      if ((rows[row] & (uint8_t)(0x10U >> column)) != 0U)
        filled_rectangle(bitmap, x + column * scale, y + row * scale,
                         scale, scale);
    }
  }
}

static const uint8_t *
glyph_for_character(char character)
{
  static const struct {
    char character;
    uint8_t rows[7];
  } glyphs[] = {
    {'J', {0x07, 0x02, 0x02, 0x02, 0x12, 0x12, 0x0c}},
    {'O', {0x0e, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0e}},
    {'H', {0x11, 0x11, 0x11, 0x1f, 0x11, 0x11, 0x11}},
    {'N', {0x11, 0x19, 0x19, 0x15, 0x13, 0x13, 0x11}},
    {'D', {0x1e, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1e}},
    {'E', {0x1f, 0x10, 0x10, 0x1e, 0x10, 0x10, 0x1f}},
    {' ', {0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00}}
  };
  size_t index;

  for (index = 0; index < sizeof(glyphs) / sizeof(glyphs[0]); ++index) {
    if (glyphs[index].character == character)
      return glyphs[index].rows;
  }

  return glyphs[sizeof(glyphs) / sizeof(glyphs[0]) - 1U].rows;
}

static void
draw_centered_text(bitmap_t *bitmap, int y, const char *text, int scale)
{
  size_t index;
  size_t length = strlen(text);
  int text_width = (int)((length * 6U - 1U) * (size_t)scale);
  int x = ((int)bitmap->width - text_width) / 2;

  for (index = 0; index < length; ++index) {
    draw_glyph(bitmap, x + (int)index * 6 * scale, y,
               glyph_for_character(text[index]), scale);
  }
}

static void
draw_code128_c(bitmap_t *bitmap, int y, int height, int module_width)
{
  /*
   * Code 128 subset B for "JOHNDOE":
   * Start B, J, O, H, N, D, O, E, checksum 29, stop.
   */
  static const char *patterns[] = {
    "211214", "112133", "133121", "231113", "113321",
    "112313", "133121", "132113", "322211", "2331112"
  };
  int total_modules = 112;
  int x = ((int)bitmap->width - total_modules * module_width) / 2;
  size_t pattern_index;

  for (pattern_index = 0;
       pattern_index < sizeof(patterns) / sizeof(patterns[0]);
       ++pattern_index) {
    const char *pattern = patterns[pattern_index];
    size_t element;

    for (element = 0; pattern[element] != '\0'; ++element) {
      int element_width = (pattern[element] - '0') * module_width;
      if ((element % 2U) == 0U)
        filled_rectangle(bitmap, x, y, element_width, height);
      x += element_width;
    }
  }
}

static void
draw_test_page(bitmap_t *bitmap)
{
  rectangle_outline(bitmap, 8, 8, (int)bitmap->width - 16,
                    (int)bitmap->height - 16, 3);
  draw_code128_c(bitmap, 30, 130, 3);
  draw_centered_text(bitmap, 205, "JOHN DOE", 9);
}

int
main(void)
{
  cups_page_header2_t header;
  cups_raster_t *raster = NULL;
  bitmap_t bitmap;
  size_t bitmap_size = (size_t)TEST_BYTES_PER_LINE * TEST_HEIGHT;
  unsigned int row;
  int status = EXIT_FAILURE;

  memset(&header, 0, sizeof(header));
  memset(&bitmap, 0, sizeof(bitmap));

  bitmap.pixels = (unsigned char *)calloc(1, bitmap_size);
  if (bitmap.pixels == NULL) {
    fprintf(stderr, "ERROR: unable to allocate test raster: %s\n",
            strerror(errno));
    return EXIT_FAILURE;
  }

  bitmap.width = TEST_WIDTH;
  bitmap.height = TEST_HEIGHT;
  bitmap.bytes_per_line = TEST_BYTES_PER_LINE;
  draw_test_page(&bitmap);

  header.HWResolution[0] = TEST_DPI;
  header.HWResolution[1] = TEST_DPI;
  header.PageSize[0] = 288U;
  header.PageSize[1] = 108U;
  header.ImagingBoundingBox[0] = 0U;
  header.ImagingBoundingBox[1] = 0U;
  header.ImagingBoundingBox[2] = 288U;
  header.ImagingBoundingBox[3] = 108U;
  header.NumCopies = 1U;
  header.cupsWidth = TEST_WIDTH;
  header.cupsHeight = TEST_HEIGHT;
  header.cupsBitsPerColor = 1U;
  header.cupsBitsPerPixel = 1U;
  header.cupsBytesPerLine = TEST_BYTES_PER_LINE;
  header.cupsColorOrder = CUPS_ORDER_CHUNKED;
  header.cupsColorSpace = CUPS_CSPACE_K;
  snprintf(header.cupsPageSizeName, sizeof(header.cupsPageSizeName),
           "%s", "w288h108");

  raster = cupsRasterOpen(STDOUT_FILENO, CUPS_RASTER_WRITE);
  if (raster == NULL) {
    fprintf(stderr, "ERROR: unable to open test raster output\n");
    goto cleanup;
  }

  if (!cupsRasterWriteHeader2(raster, &header)) {
    fprintf(stderr, "ERROR: unable to write test raster header\n");
    goto cleanup;
  }

  for (row = 0; row < TEST_HEIGHT; ++row) {
    unsigned char *line =
        bitmap.pixels + (size_t)row * TEST_BYTES_PER_LINE;
    if (cupsRasterWritePixels(raster, line, TEST_BYTES_PER_LINE) !=
        TEST_BYTES_PER_LINE) {
      fprintf(stderr, "ERROR: unable to write test raster row %u\n", row);
      goto cleanup;
    }
  }

  status = EXIT_SUCCESS;

cleanup:
  if (raster != NULL)
    cupsRasterClose(raster);
  free(bitmap.pixels);
  return status;
}
