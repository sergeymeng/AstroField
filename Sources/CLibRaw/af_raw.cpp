#include "af_raw.h"

#include <libraw/libraw.h>

#include <cstdlib>
#include <cstring>
#include <string>

namespace {

char *copyMessage(const std::string &text) {
    char *out = static_cast<char *>(std::malloc(text.size() + 1));
    if (!out) return nullptr;
    std::memcpy(out, text.c_str(), text.size() + 1);
    return out;
}

int fail(libraw_data_t *raw, int code, const char *stage, char **error) {
    std::string message(stage);
    message += ": ";
    message += libraw_strerror(code);
    if (error) *error = copyMessage(message);
    if (raw) libraw_close(raw);
    return code == 0 ? -1 : code;
}

}  // namespace

int af_raw_decode_luma(const char *path,
                       unsigned short **out,
                       int *width, int *height,
                       int *black, int *white,
                       char **error) {
    if (out) *out = nullptr;
    if (error) *error = nullptr;
    libraw_data_t *raw = libraw_init(0);
    if (!raw) {
        if (error) *error = copyMessage("libraw_init failed");
        return -1;
    }
    int ret = libraw_open_file(raw, path);
    if (ret != LIBRAW_SUCCESS) return fail(raw, ret, "open", error);

    raw->params.half_size = 1;
    raw->params.output_bps = 16;
    raw->params.no_auto_bright = 1;
    raw->params.gamm[0] = 1.0;
    raw->params.gamm[1] = 1.0;
    raw->params.user_mul[0] = 1.0f;
    raw->params.user_mul[1] = 1.0f;
    raw->params.user_mul[2] = 1.0f;
    raw->params.user_mul[3] = 1.0f;
    raw->params.use_camera_matrix = 0;

    ret = libraw_unpack(raw);
    if (ret != LIBRAW_SUCCESS) return fail(raw, ret, "unpack", error);
    ret = libraw_dcraw_process(raw);
    if (ret != LIBRAW_SUCCESS) return fail(raw, ret, "process", error);

    int memoryError = 0;
    libraw_processed_image_t *image = libraw_dcraw_make_mem_image(raw, &memoryError);
    if (!image) {
        if (error) *error = copyMessage("dcraw_make_mem_image failed");
        libraw_close(raw);
        return -1;
    }
    if (image->type != LIBRAW_IMAGE_BITMAP || image->colors != 3 || image->bits != 16) {
        if (error) *error = copyMessage("unexpected decoded image format");
        libraw_dcraw_clear_mem(image);
        libraw_close(raw);
        return -1;
    }

    const int w = static_cast<int>(image->width);
    const int h = static_cast<int>(image->height);
    unsigned short *luma = static_cast<unsigned short *>(
        std::malloc(static_cast<size_t>(w) * static_cast<size_t>(h) * sizeof(unsigned short)));
    if (!luma) {
        if (error) *error = copyMessage("out of memory for luma buffer");
        libraw_dcraw_clear_mem(image);
        libraw_close(raw);
        return -1;
    }

    const unsigned short *source = reinterpret_cast<const unsigned short *>(image->data);
    const size_t count = static_cast<size_t>(w) * static_cast<size_t>(h);
    for (size_t i = 0; i < count; ++i) {
        const float r = static_cast<float>(source[i * 3 + 0]);
        const float g = static_cast<float>(source[i * 3 + 1]);
        const float b = static_cast<float>(source[i * 3 + 2]);
        float y = 0.2126f * r + 0.7152f * g + 0.0722f * b;
        if (y < 0) y = 0;
        if (y > 65535) y = 65535;
        luma[i] = static_cast<unsigned short>(y + 0.5f);
    }

    if (width) *width = w;
    if (height) *height = h;
    if (black) *black = static_cast<int>(raw->rawdata.color.black);
    if (white) *white = static_cast<int>(raw->rawdata.color.maximum);
    *out = luma;

    libraw_dcraw_clear_mem(image);
    libraw_close(raw);
    return 0;
}

void af_raw_free(void *pointer) {
    if (pointer) std::free(pointer);
}
