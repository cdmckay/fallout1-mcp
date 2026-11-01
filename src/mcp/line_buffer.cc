#include "mcp/line_buffer.h"

#include <cstring>

namespace fallout {

LineBuffer::LineBuffer(size_t maxLineLength)
    : _maxLineLength(maxLineLength)
    , _discarding(false)
{
}

int LineBuffer::append(const char* data, size_t length, std::vector<std::string>& lines)
{
    int dropped = 0;

    while (length > 0) {
        const char* newline = static_cast<const char*>(memchr(data, '\n', length));
        size_t chunk = newline != nullptr ? static_cast<size_t>(newline - data) : length;

        if (!_discarding) {
            if (_pending.size() + chunk > _maxLineLength) {
                _pending.clear();
                _discarding = true;
                dropped++;
            } else {
                _pending.append(data, chunk);
            }
        }

        if (newline == nullptr) {
            break;
        }

        if (!_discarding) {
            if (!_pending.empty() && _pending.back() == '\r') {
                _pending.pop_back();
            }
            lines.push_back(std::move(_pending));
        }

        _pending.clear();
        _discarding = false;

        data += chunk + 1;
        length -= chunk + 1;
    }

    return dropped;
}

void LineBuffer::clear()
{
    _pending.clear();
    _discarding = false;
}

} // namespace fallout
