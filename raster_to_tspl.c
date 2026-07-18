/*
 * raster_to_tspl.c
 *
 * CUPS raster filter for the LabelPrinter/OCOM OCBP-T4201 (TSPL2, 203 dpi).
 *
 * The filter accepts the normal CUPS filter command line:
 *
 *   raster_to_tspl job-id user title copies options [raster-file]
 *
 * It also accepts raster data on stdin when invoked without arguments, which is
 * useful for testing. TSPL is written to stdout; diagnostics go to stderr.
 */

#include <cups/cups.h>
#include <cups/raster.h>

#include <errno.h>
#include <fcntl.h>
#include <locale.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>

#define TSPL_COMMAND_MAX 256
#define MAX_RASTER_DIMENSION 200000U
#define MAX_RASTER_LINE_BYTES (128U * 1024U * 1024U)

typedef enum {
  MEDIA_GAP,
  MEDIA_BLACK_MARK,
  MEDIA_CONTINUOUS
} media_type_t;

typedef enum {
  ACTION_NONE,
  ACTION_TEAR,
  ACTION_PEEL,
  ACTION_CUT
} post_action_t;

typedef struct {
  media_type_t media_type;
  post_action_t post_action;
  int gap_mm;
  int speed;
  int darkness;
  int ribbon;
  int x_offset_mm;
  int y_offset_mm;
} filter_settings_t;

static volatile sig_atomic_t cancelled = 0;

static void
cancel_job(int signal_number)
{
  (void)signal_number;
  cancelled = 1;
}

static void
log_message(const char *level, const char *format, ...)
{
  va_list arguments;

  fprintf(stderr, "%s: ", level);
  va_start(arguments, format);
  vfprintf(stderr, format, arguments);
  va_end(arguments);
  fputc('\n', stderr);
}

static bool
write_bytes(const void *data, size_t length)
{
  const unsigned char *cursor = (const unsigned char *)data;

  while (length > 0) {
    size_t written = fwrite(cursor, 1, length, stdout);

    if (written == 0) {
      log_message("ERROR", "Unable to write printer data: %s",
                  ferror(stdout) ? strerror(errno) : "short write");
      return false;
    }

    cursor += written;
    length -= written;
  }

  return true;
}

static bool
write_command(const char *format, ...)
{
  char command[TSPL_COMMAND_MAX];
  va_list arguments;
  int length;

  va_start(arguments, format);
  length = vsnprintf(command, sizeof(command), format, arguments);
  va_end(arguments);

  if (length < 0 || (size_t)length >= sizeof(command)) {
    log_message("ERROR", "Internal TSPL command buffer overflow");
    return false;
  }

  return write_bytes(command, (size_t)length);
}

static bool
parse_bounded_integer(const char *value, int minimum, int maximum, int *result)
{
  char *end = NULL;
  long parsed;

  if (value == NULL || *value == '\0')
    return false;

  errno = 0;
  parsed = strtol(value, &end, 10);
  if (errno != 0 || end == value || (*end != '\0' && strcmp(end, "mm") != 0) ||
      parsed < minimum || parsed > maximum)
    return false;

  *result = (int)parsed;
  return true;
}

static void
load_settings(const char *option_string, filter_settings_t *settings)
{
  cups_option_t *options = NULL;
  int option_count = 0;
  const char *value;
  int parsed;

  settings->media_type = MEDIA_GAP;
  settings->post_action = ACTION_TEAR;
  settings->gap_mm = 3;
  settings->speed = 5;
  settings->darkness = 8;
  settings->ribbon = 1;
  settings->x_offset_mm = 0;
  settings->y_offset_mm = 0;

  if (option_string == NULL || *option_string == '\0')
    return;

  option_count = cupsParseOptions(option_string, 0, &options);

  value = cupsGetOption("PaperType", option_count, options);
  if (value != NULL) {
    if (strcasecmp(value, "LabelMark") == 0)
      settings->media_type = MEDIA_BLACK_MARK;
    else if (strcasecmp(value, "Continue") == 0)
      settings->media_type = MEDIA_CONTINUOUS;
  }

  value = cupsGetOption("GapsHeight", option_count, options);
  if (parse_bounded_integer(value, 0, 10, &parsed))
    settings->gap_mm = parsed;

  value = cupsGetOption("PrintSpeed", option_count, options);
  if (parse_bounded_integer(value, 2, 6, &parsed))
    settings->speed = parsed;

  value = cupsGetOption("Darkness", option_count, options);
  if (parse_bounded_integer(value, 0, 15, &parsed))
    settings->darkness = parsed;

  value = cupsGetOption("MediaMethod", option_count, options);
  if (value != NULL && strcasecmp(value, "Direct") == 0)
    settings->ribbon = 0;

  value = cupsGetOption("PostAction", option_count, options);
  if (value != NULL) {
    if (strcasecmp(value, "None") == 0)
      settings->post_action = ACTION_NONE;
    else if (strcasecmp(value, "PeelOff") == 0)
      settings->post_action = ACTION_PEEL;
    else if (strcasecmp(value, "Cut") == 0)
      settings->post_action = ACTION_CUT;
  }

  value = cupsGetOption("Horizontal", option_count, options);
  if (parse_bounded_integer(value, -10, 10, &parsed))
    settings->x_offset_mm = parsed;

  value = cupsGetOption("Vertical", option_count, options);
  if (parse_bounded_integer(value, -10, 10, &parsed))
    settings->y_offset_mm = parsed;

  cupsFreeOptions(option_count, options);
}

static bool
is_additive_gray(cups_cspace_t color_space)
{
  return color_space == CUPS_CSPACE_W || color_space == CUPS_CSPACE_SW;
}

static bool
packed_pixel_is_black(const unsigned char *line, unsigned int x,
                      cups_cspace_t color_space)
{
  bool bit_is_set = (line[x / 8U] & (0x80U >> (x % 8U))) != 0;

  /*
   * CUPS K uses 0 for no ink and 1 for black ink. Additive W/SW uses 0 for
   * black and 1 for white. The supplied PPD requests K.
   */
  return is_additive_gray(color_space) ? !bit_is_set : bit_is_set;
}

static unsigned int
subtractive_blackness(unsigned int cyan, unsigned int magenta,
                      unsigned int yellow, unsigned int black)
{
  unsigned int process_ink =
      (299U * cyan + 587U * magenta + 114U * yellow + 500U) / 1000U;
  return process_ink > black ? process_ink : black;
}

static bool
byte_pixel_is_black(const unsigned char *pixel, unsigned int components,
                    cups_cspace_t color_space)
{
  unsigned int blackness;

  switch (color_space) {
    case CUPS_CSPACE_K:
      return pixel[0] >= 128U;

    case CUPS_CSPACE_W:
    case CUPS_CSPACE_SW:
      return pixel[0] < 128U;

    case CUPS_CSPACE_RGB:
    case CUPS_CSPACE_SRGB:
    case CUPS_CSPACE_ADOBERGB:
    case CUPS_CSPACE_RGBA:
    case CUPS_CSPACE_RGBW:
      if (components < 3U)
        return false;
      return (299U * pixel[0] + 587U * pixel[1] + 114U * pixel[2]) <
             128000U;

    case CUPS_CSPACE_CMY:
      if (components < 3U)
        return false;
      return subtractive_blackness(pixel[0], pixel[1], pixel[2], 0U) >= 128U;

    case CUPS_CSPACE_YMC:
      if (components < 3U)
        return false;
      return subtractive_blackness(pixel[2], pixel[1], pixel[0], 0U) >= 128U;

    case CUPS_CSPACE_CMYK:
      if (components < 4U)
        return false;
      blackness = subtractive_blackness(pixel[0], pixel[1], pixel[2], pixel[3]);
      return blackness >= 128U;

    case CUPS_CSPACE_YMCK:
      if (components < 4U)
        return false;
      blackness = subtractive_blackness(pixel[2], pixel[1], pixel[0], pixel[3]);
      return blackness >= 128U;

    case CUPS_CSPACE_KCMY:
    case CUPS_CSPACE_KCMYcm:
      if (components < 4U)
        return false;
      blackness = subtractive_blackness(pixel[1], pixel[2], pixel[3], pixel[0]);
      return blackness >= 128U;

    default:
      /*
       * Unknown one-component spaces are treated as additive grayscale.
       * Multi-component ICC/Lab data is rejected by returning white; the PPD
       * never asks the rasterizer for those spaces.
       */
      return components == 1U && pixel[0] < 128U;
  }
}

static bool
convert_line(const cups_page_header2_t *header, const unsigned char *source,
             unsigned char *destination, size_t destination_size)
{
  unsigned int x;

  /*
   * TSPL bitmap data uses 1 for an unheated (white) dot and 0 for a heated
   * (black) dot on this printer. Start with a white row, then clear black dots.
   * This polarity matches the working OCBP-T4201 macOS manufacturer filter.
   */
  memset(destination, 0xff, destination_size);

  if (header->cupsBitsPerColor == 1U && header->cupsBitsPerPixel == 1U) {
    for (x = 0; x < header->cupsWidth; ++x) {
      if (packed_pixel_is_black(source, x, header->cupsColorSpace))
        destination[x / 8U] &= (unsigned char)~(0x80U >> (x % 8U));
    }
    return true;
  }

  if (header->cupsBitsPerColor == 8U &&
      header->cupsBitsPerPixel >= 8U &&
      (header->cupsBitsPerPixel % 8U) == 0U) {
    unsigned int components = header->cupsBitsPerPixel / 8U;

    for (x = 0; x < header->cupsWidth; ++x) {
      const unsigned char *pixel = source + ((size_t)x * components);
      if (byte_pixel_is_black(pixel, components, header->cupsColorSpace))
        destination[x / 8U] &= (unsigned char)~(0x80U >> (x % 8U));
    }
    return true;
  }

  log_message("ERROR",
              "Unsupported raster format: %u bits/color, %u bits/pixel, "
              "color space %d",
              header->cupsBitsPerColor, header->cupsBitsPerPixel,
              (int)header->cupsColorSpace);
  return false;
}

static bool
validate_header(const cups_page_header2_t *header)
{
  size_t minimum_line_bytes;

  if (header->cupsWidth == 0U || header->cupsHeight == 0U ||
      header->cupsWidth > MAX_RASTER_DIMENSION ||
      header->cupsHeight > MAX_RASTER_DIMENSION) {
    log_message("ERROR", "Invalid raster dimensions: %ux%u",
                header->cupsWidth, header->cupsHeight);
    return false;
  }

  if (header->HWResolution[0] == 0U || header->HWResolution[1] == 0U) {
    log_message("ERROR", "Raster page has no usable resolution");
    return false;
  }

  if (header->cupsColorOrder != CUPS_ORDER_CHUNKED) {
    log_message("ERROR", "Only chunked CUPS raster data is supported");
    return false;
  }

  if (header->cupsBitsPerPixel == 0U) {
    log_message("ERROR", "Raster page has zero bits per pixel");
    return false;
  }

  minimum_line_bytes =
      (((size_t)header->cupsWidth * header->cupsBitsPerPixel) + 7U) / 8U;
  if (header->cupsBytesPerLine < minimum_line_bytes ||
      header->cupsBytesPerLine > MAX_RASTER_LINE_BYTES) {
    log_message("ERROR", "Invalid raster line size: %u bytes",
                header->cupsBytesPerLine);
    return false;
  }

  return true;
}

static bool
write_page_setup(const cups_page_header2_t *header,
                 const filter_settings_t *settings)
{
  double width_mm;
  double height_mm;
  int x_dots =
      (int)((double)settings->x_offset_mm * header->HWResolution[0] / 25.4);
  int y_dots =
      (int)((double)settings->y_offset_mm * header->HWResolution[1] / 25.4);

  /*
   * PageSize is expressed in PostScript points and preserves exact requested
   * media dimensions such as 38.1 mm, which lies between two dots at 203 dpi.
   * Fall back to raster geometry when a producer leaves PageSize unset.
   */
  if (header->PageSize[0] > 0U && header->PageSize[1] > 0U) {
    width_mm = (double)header->PageSize[0] * 25.4 / 72.0;
    height_mm = (double)header->PageSize[1] * 25.4 / 72.0;
  } else {
    width_mm =
        (double)header->cupsWidth * 25.4 / (double)header->HWResolution[0];
    height_mm =
        (double)header->cupsHeight * 25.4 / (double)header->HWResolution[1];
  }

  if (!write_command("SIZE %.1f mm,%.1f mm\r\n", width_mm, height_mm))
    return false;

  if (settings->media_type == MEDIA_BLACK_MARK) {
    if (!write_command("BLINE %d.0 mm,0.0 mm\r\n", settings->gap_mm))
      return false;
  } else if (settings->media_type == MEDIA_CONTINUOUS) {
    if (!write_command("GAP 0.0 mm,0.0 mm\r\n"))
      return false;
  } else if (!write_command("GAP %d.0 mm,0.0 mm\r\n", settings->gap_mm)) {
    return false;
  }

  if (!write_command("SPEED %d\r\n", settings->speed) ||
      !write_command("DENSITY %d\r\n", settings->darkness) ||
      !write_command("SET RIBBON %s\r\n", settings->ribbon ? "ON" : "OFF") ||
      !write_command("DIRECTION 0,0\r\n") ||
      !write_command("REFERENCE %d,%d\r\n", x_dots, y_dots) ||
      !write_command("OFFSET 0.0 mm\r\n") ||
      !write_command("SET TEAR OFF\r\n") ||
      !write_command("SET PEEL OFF\r\n") ||
      !write_command("SET CUTTER OFF\r\n")) {
    return false;
  }

  switch (settings->post_action) {
    case ACTION_TEAR:
      if (!write_command("SET TEAR ON\r\n"))
        return false;
      break;
    case ACTION_PEEL:
      if (!write_command("SET PEEL ON\r\n"))
        return false;
      break;
    case ACTION_CUT:
      if (!write_command("SET CUTTER 1\r\n"))
        return false;
      break;
    case ACTION_NONE:
      break;
  }

  return write_command("CLS\r\n");
}

static int
page_copies(const cups_page_header2_t *header, int requested_copies)
{
  unsigned int copies = header->NumCopies;

  if (copies == 0U)
    copies = requested_copies > 0 ? (unsigned int)requested_copies : 1U;
  if (copies > 999U)
    copies = 999U;

  return (int)copies;
}

static bool
process_page(cups_raster_t *raster, const cups_page_header2_t *header,
             const filter_settings_t *settings, unsigned int page_number,
             int requested_copies)
{
  unsigned char *source_line = NULL;
  unsigned char *bitmap_line = NULL;
  size_t bitmap_line_size = ((size_t)header->cupsWidth + 7U) / 8U;
  unsigned int y;
  bool success = false;
  int copies = page_copies(header, requested_copies);

  source_line = (unsigned char *)malloc(header->cupsBytesPerLine);
  bitmap_line = (unsigned char *)malloc(bitmap_line_size);
  if (source_line == NULL || bitmap_line == NULL) {
    log_message("ERROR", "Out of memory while allocating raster buffers");
    goto cleanup;
  }

  fprintf(stderr, "PAGE: %u %d\n", page_number, copies);
  log_message("DEBUG", "Page %u: %ux%u dots, %ux%u dpi, %zu bitmap bytes/line",
              page_number, header->cupsWidth, header->cupsHeight,
              header->HWResolution[0], header->HWResolution[1],
              bitmap_line_size);

  if (!write_page_setup(header, settings) ||
      !write_command("BITMAP 0,0,%zu,%u,0,", bitmap_line_size,
                     header->cupsHeight)) {
    goto cleanup;
  }

  for (y = 0; y < header->cupsHeight && !cancelled; ++y) {
    unsigned int bytes_read =
        cupsRasterReadPixels(raster, source_line, header->cupsBytesPerLine);

    if (bytes_read != header->cupsBytesPerLine) {
      log_message("ERROR",
                  "Short raster read on page %u, row %u: expected %u bytes, "
                  "received %u",
                  page_number, y, header->cupsBytesPerLine, bytes_read);
      goto cleanup;
    }

    if (!convert_line(header, source_line, bitmap_line, bitmap_line_size) ||
        !write_bytes(bitmap_line, bitmap_line_size)) {
      goto cleanup;
    }
  }

  if (cancelled)
    goto cleanup;

  if (!write_command("\r\nPRINT 1,%d\r\n", copies))
    goto cleanup;

  success = true;

cleanup:
  free(bitmap_line);
  free(source_line);
  return success;
}

int
main(int argc, char *argv[])
{
  cups_raster_t *raster = NULL;
  cups_page_header2_t header;
  filter_settings_t settings;
  int input_fd = STDIN_FILENO;
  bool close_input = false;
  unsigned int page_number = 0;
  int requested_copies = 1;
  int status = EXIT_FAILURE;

  setlocale(LC_NUMERIC, "C");
  signal(SIGTERM, cancel_job);
  signal(SIGINT, cancel_job);
  signal(SIGPIPE, SIG_IGN);

  if (argc != 1 && argc != 6 && argc != 7) {
    log_message("ERROR",
                "Usage: %s job-id user title copies options [raster-file]",
                argv[0]);
    return EXIT_FAILURE;
  }

  if (argc >= 6) {
    if (!parse_bounded_integer(argv[4], 1, 999, &requested_copies))
      requested_copies = 1;
    load_settings(argv[5], &settings);
  } else {
    load_settings(NULL, &settings);
  }

  if (argc == 7) {
    input_fd = open(argv[6], O_RDONLY);
    if (input_fd < 0) {
      log_message("ERROR", "Unable to open raster file '%s': %s",
                  argv[6], strerror(errno));
      return EXIT_FAILURE;
    }
    close_input = true;
  }

  raster = cupsRasterOpen(input_fd, CUPS_RASTER_READ);
  if (raster == NULL) {
    log_message("ERROR", "Unable to open CUPS raster stream");
    goto cleanup;
  }

  while (!cancelled && cupsRasterReadHeader2(raster, &header)) {
    ++page_number;

    if (!validate_header(&header) ||
        !process_page(raster, &header, &settings, page_number,
                      requested_copies)) {
      goto cleanup;
    }
  }

  if (cancelled) {
    log_message("INFO", "Print job cancelled");
    status = EXIT_SUCCESS;
  } else if (page_number == 0U) {
    log_message("ERROR", "Raster stream contained no pages");
  } else if (fflush(stdout) != 0 || ferror(stdout)) {
    log_message("ERROR", "Unable to flush printer data: %s", strerror(errno));
  } else {
    status = EXIT_SUCCESS;
  }

cleanup:
  if (raster != NULL)
    cupsRasterClose(raster);
  if (close_input)
    close(input_fd);

  return status;
}
