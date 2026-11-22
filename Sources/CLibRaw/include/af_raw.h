#ifndef AF_RAW_H
#define AF_RAW_H

#ifdef __cplusplus
extern "C" {
#endif

/* Decode a RAW file with LibRaw into a linear luminance image.
 *
 * `half_size` decoding is used (4128x2752 for a 45 MP body). On success:
 *   - returns 0
 *   - *out is a malloc'ed width*height array of 16-bit luminance
 *   - *black / *white carry the sensor black and white levels
 * Caller must release *out and *error with af_raw_free().
 * On failure returns a nonzero code and sets *error to a malloc'ed message.
 */
int af_raw_decode_luma(const char *path,
                       unsigned short **out,
                       int *width, int *height,
                       int *black, int *white,
                       char **error);

void af_raw_free(void *pointer);

#ifdef __cplusplus
}
#endif

#endif
