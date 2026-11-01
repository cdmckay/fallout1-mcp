#include "mcp/png.h"

#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STB_IMAGE_WRITE_STATIC
#include <stb_image_write.h>

namespace fallout {

static void append_bytes(void* context, void* data, int size)
{
    std::vector<unsigned char>* png = static_cast<std::vector<unsigned char>*>(context);
    unsigned char* bytes = static_cast<unsigned char*>(data);
    png->insert(png->end(), bytes, bytes + size);
}

bool mcp_encode_png(SDL_Surface* surface, std::vector<unsigned char>& png)
{
    if (surface == nullptr) {
        return false;
    }

    SDL_Surface* rgb = SDL_ConvertSurfaceFormat(surface, SDL_PIXELFORMAT_RGB24, 0);
    if (rgb == nullptr) {
        return false;
    }

    png.clear();
    int ok = stbi_write_png_to_func(append_bytes, &png, rgb->w, rgb->h, 3, rgb->pixels, rgb->pitch);
    SDL_FreeSurface(rgb);

    return ok != 0;
}

std::string mcp_base64(const unsigned char* data, size_t length)
{
    static const char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    std::string out;
    out.reserve((length + 2) / 3 * 4);

    size_t i = 0;
    for (; i + 2 < length; i += 3) {
        unsigned int n = (data[i] << 16) | (data[i + 1] << 8) | data[i + 2];
        out += alphabet[(n >> 18) & 63];
        out += alphabet[(n >> 12) & 63];
        out += alphabet[(n >> 6) & 63];
        out += alphabet[n & 63];
    }

    if (i < length) {
        unsigned int n = data[i] << 16;
        if (i + 1 < length) {
            n |= data[i + 1] << 8;
        }
        out += alphabet[(n >> 18) & 63];
        out += alphabet[(n >> 12) & 63];
        out += i + 1 < length ? alphabet[(n >> 6) & 63] : '=';
        out += '=';
    }

    return out;
}

} // namespace fallout
