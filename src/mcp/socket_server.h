#ifndef FALLOUT_MCP_SOCKET_SERVER_H_
#define FALLOUT_MCP_SOCKET_SERVER_H_

#include <cstddef>
#include <string>
#include <vector>

#include "mcp/line_buffer.h"

namespace fallout {

// What happened during one `SocketServer::poll`.
struct SocketEvents {
    // A client connected. When a new client arrives while one is connected,
    // the old one is dropped first, so a restarted bridge never waits behind a
    // dead connection; both flags are set then.
    bool connected = false;
    bool disconnected = false;

    // Lines dropped for exceeding the length limit.
    int dropped = 0;
};

// A Unix-domain socket that serves one client at a time with
// newline-delimited messages, without ever blocking the game.
class SocketServer {
public:
    static const size_t kMaxLineLength = 1 << 20;
    static const size_t kMaxPendingOutput = 64 << 20;

    SocketServer();
    ~SocketServer();

    // Creates the socket at `path`, replacing a stale socket left by an
    // earlier run but not a live one, and makes it accessible to the owner
    // only.
    bool listen(const std::string& path, std::string& error);

    // Closes any client and the socket, and removes the socket file.
    void close();

    // Accepts a waiting client, reads what has arrived and sends pending
    // output. Complete lines are appended to `lines`.
    SocketEvents poll(std::vector<std::string>& lines);

    // Queues `line` and a newline for the client and sends as much as the
    // socket takes right away; `poll` sends the rest. Returns false when no
    // client is connected.
    bool send(const std::string& line);

    bool hasClient() const;

private:
    void dropClient();
    bool flush();

    std::string _path;
    int _listenFd;
    int _clientFd;

    // Set when `send` drops the client, so the next `poll` reports it.
    bool _lostClient;
    LineBuffer _input;
    std::string _output;
};

} // namespace fallout

#endif /* FALLOUT_MCP_SOCKET_SERVER_H_ */
