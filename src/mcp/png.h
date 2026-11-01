#ifndef FALLOUT_MCP_PNG_H_
#define FALLOUT_MCP_PNG_H_

#include <cstddef>
#include <string>
#include <vector>

#include <SDL.h>

namespace fallout {

// Encodes `surface`, in any pixel format SDL can convert to RGB24, as a PNG.
bool mcp_encode_png(SDL_Surface* surface, std::vector<unsigned char>& png);

// Standard base64 (RFC 4648) with padding, as MCP image content expects.
std::string mcp_base64(const unsigned char* data, size_t length);

} // namespace fallout

#endif /* FALLOUT_MCP_PNG_H_ */
