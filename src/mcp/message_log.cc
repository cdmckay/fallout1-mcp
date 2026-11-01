#include "mcp/message_log.h"

namespace fallout {

MessageLog::MessageLog(size_t capacity)
    : _capacity(capacity)
    , _latest(0)
{
}

void MessageLog::add(const std::string& text)
{
    _lines.emplace_back(++_latest, text);
    while (_lines.size() > _capacity) {
        _lines.pop_front();
    }
}

std::vector<std::pair<long long, std::string>> MessageLog::since(long long after) const
{
    std::vector<std::pair<long long, std::string>> lines;
    for (const auto& line : _lines) {
        if (line.first > after) {
            lines.push_back(line);
        }
    }
    return lines;
}

long long MessageLog::latest() const
{
    return _latest;
}

} // namespace fallout
