#ifndef FALLOUT_MCP_LINE_BUFFER_H_
#define FALLOUT_MCP_LINE_BUFFER_H_

#include <cstddef>
#include <string>
#include <vector>

namespace fallout {

// Splits a byte stream into newline-terminated lines, as the MCP socket
// receives them. A line longer than the limit is dropped whole.
class LineBuffer {
public:
    explicit LineBuffer(size_t maxLineLength);

    // Appends `length` bytes and moves every completed line, without its
    // newline, into `lines`. Returns how many lines were dropped for being too
    // long.
    int append(const char* data, size_t length, std::vector<std::string>& lines);

    void clear();

private:
    const size_t _maxLineLength;
    std::string _pending;

    // Set while skipping the rest of an over-long line.
    bool _discarding;
};

} // namespace fallout

#endif /* FALLOUT_MCP_LINE_BUFFER_H_ */
