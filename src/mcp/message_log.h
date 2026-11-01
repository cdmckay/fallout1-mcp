#ifndef FALLOUT_MCP_MESSAGE_LOG_H_
#define FALLOUT_MCP_MESSAGE_LOG_H_

#include <cstddef>
#include <deque>
#include <string>
#include <utility>
#include <vector>

namespace fallout {

// The lines the game prints to its message window, numbered so a reader can
// ask for what's new since it last looked. Keeps the most recent `capacity`.
class MessageLog {
public:
    explicit MessageLog(size_t capacity);

    void add(const std::string& text);

    // Lines numbered after `after`, oldest first.
    std::vector<std::pair<long long, std::string>> since(long long after) const;

    // The newest line's number, 0 before the first.
    long long latest() const;

private:
    const size_t _capacity;
    std::deque<std::pair<long long, std::string>> _lines;
    long long _latest;
};

} // namespace fallout

#endif /* FALLOUT_MCP_MESSAGE_LOG_H_ */
