#include "mcp/png.h"

#include <catch2/catch_test_macros.hpp>

#define STB_IMAGE_IMPLEMENTATION
#define STB_IMAGE_STATIC
#include <stb_image.h>

using fallout::mcp_base64;
using fallout::mcp_encode_png;

static std::string base64(const char* text)
{
    return mcp_base64(reinterpret_cast<const unsigned char*>(text), strlen(text));
}

TEST_CASE("mcp_base64 matches the RFC 4648 test vectors")
{
    REQUIRE(base64("") == "");
    REQUIRE(base64("f") == "Zg==");
    REQUIRE(base64("fo") == "Zm8=");
    REQUIRE(base64("foo") == "Zm9v");
    REQUIRE(base64("foob") == "Zm9vYg==");
    REQUIRE(base64("fooba") == "Zm9vYmE=");
    REQUIRE(base64("foobar") == "Zm9vYmFy");
}

TEST_CASE("mcp_base64 handles every byte value")
{
    const unsigned char bytes[] = { 0x00, 0xff, 0xfe, 0x80 };
    REQUIRE(mcp_base64(bytes, sizeof(bytes)) == "AP/+gA==");
}

TEST_CASE("mcp_encode_png round-trips the game's RGB888 frame format")
{
    // The same format as gSdlTextureSurface.
    SDL_Surface* surface = SDL_CreateRGBSurfaceWithFormat(0, 3, 2, 32, SDL_PIXELFORMAT_RGB888);
    REQUIRE(surface != nullptr);

    const Uint8 expected[2][3][3] = {
        { { 255, 0, 0 }, { 0, 255, 0 }, { 0, 0, 255 } },
        { { 10, 20, 30 }, { 128, 128, 128 }, { 255, 255, 255 } },
    };
    for (int y = 0; y < 2; y++) {
        Uint32* row = reinterpret_cast<Uint32*>(static_cast<Uint8*>(surface->pixels) + y * surface->pitch);
        for (int x = 0; x < 3; x++) {
            row[x] = SDL_MapRGB(surface->format, expected[y][x][0], expected[y][x][1], expected[y][x][2]);
        }
    }

    std::vector<unsigned char> png;
    REQUIRE(mcp_encode_png(surface, png));
    SDL_FreeSurface(surface);

    REQUIRE(png.size() > 8);
    REQUIRE(png[0] == 0x89);
    REQUIRE(png[1] == 'P');

    int width;
    int height;
    int channels;
    unsigned char* decoded = stbi_load_from_memory(png.data(), static_cast<int>(png.size()), &width, &height, &channels, 3);
    REQUIRE(decoded != nullptr);
    REQUIRE(width == 3);
    REQUIRE(height == 2);

    for (int y = 0; y < 2; y++) {
        for (int x = 0; x < 3; x++) {
            for (int c = 0; c < 3; c++) {
                INFO("pixel " << x << "," << y << " channel " << c);
                REQUIRE(decoded[(y * 3 + x) * 3 + c] == expected[y][x][c]);
            }
        }
    }

    stbi_image_free(decoded);
}

TEST_CASE("mcp_encode_png rejects a missing surface")
{
    std::vector<unsigned char> png;
    REQUIRE_FALSE(mcp_encode_png(nullptr, png));
}
