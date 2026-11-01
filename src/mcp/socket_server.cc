#include "mcp/socket_server.h"

#if defined(__unix__) || defined(__APPLE__)
#define MCP_HAVE_UNIX_SOCKETS 1
#endif

#ifdef MCP_HAVE_UNIX_SOCKETS
#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#endif

namespace fallout {

#ifdef MCP_HAVE_UNIX_SOCKETS

#ifdef MSG_NOSIGNAL
static const int kSendFlags = MSG_NOSIGNAL;
#else
static const int kSendFlags = 0;
#endif

// Makes `fd` non-blocking and not inherited by child processes. On macOS, which
// has no MSG_NOSIGNAL, a write to a closed peer must not raise SIGPIPE either.
static bool prepare_fd(int fd)
{
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags == -1 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) == -1) {
        return false;
    }

    if (fcntl(fd, F_SETFD, FD_CLOEXEC) == -1) {
        return false;
    }

#ifdef SO_NOSIGPIPE
    int on = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof(on));
#endif

    return true;
}

static bool make_address(const std::string& path, struct sockaddr_un* address)
{
    memset(address, 0, sizeof(*address));
    address->sun_family = AF_UNIX;
    if (path.empty() || path.size() >= sizeof(address->sun_path)) {
        return false;
    }
    memcpy(address->sun_path, path.c_str(), path.size());
    return true;
}

// Whether something is still accepting connections at `address`.
static bool socket_is_live(const struct sockaddr_un* address)
{
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd == -1) {
        return false;
    }
    bool live = connect(fd, reinterpret_cast<const struct sockaddr*>(address), sizeof(*address)) == 0;
    ::close(fd);
    return live;
}

SocketServer::SocketServer()
    : _listenFd(-1)
    , _clientFd(-1)
    , _lostClient(false)
    , _input(kMaxLineLength)
{
}

SocketServer::~SocketServer()
{
    close();
}

bool SocketServer::listen(const std::string& path, std::string& error)
{
    close();

    struct sockaddr_un address;
    if (!make_address(path, &address)) {
        error = "socket path is empty or too long: " + path;
        return false;
    }

    struct stat st;
    if (lstat(path.c_str(), &st) == 0) {
        if (!S_ISSOCK(st.st_mode)) {
            error = "refusing to replace a file that isn't a socket: " + path;
            return false;
        }
        if (socket_is_live(&address)) {
            error = "another game is already listening on " + path;
            return false;
        }
        unlink(path.c_str());
    }

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd == -1) {
        error = std::string("socket: ") + strerror(errno);
        return false;
    }

    if (!prepare_fd(fd)) {
        error = std::string("fcntl: ") + strerror(errno);
        ::close(fd);
        return false;
    }

    if (bind(fd, reinterpret_cast<struct sockaddr*>(&address), sizeof(address)) == -1) {
        error = "bind " + path + ": " + strerror(errno);
        ::close(fd);
        return false;
    }

    // The directory should already be private (the bridge puts the socket in
    // $XDG_RUNTIME_DIR); this keeps the socket itself owner-only either way.
    chmod(path.c_str(), S_IRUSR | S_IWUSR);

    if (::listen(fd, 4) == -1) {
        error = std::string("listen: ") + strerror(errno);
        ::close(fd);
        unlink(path.c_str());
        return false;
    }

    _listenFd = fd;
    _path = path;
    return true;
}

void SocketServer::close()
{
    dropClient();

    if (_listenFd != -1) {
        ::close(_listenFd);
        _listenFd = -1;
        unlink(_path.c_str());
        _path.clear();
    }
}

SocketEvents SocketServer::poll(std::vector<std::string>& lines)
{
    SocketEvents events;

    if (_listenFd == -1) {
        return events;
    }

    if (_lostClient) {
        _lostClient = false;
        events.disconnected = true;
    }

    // Newest client wins, so a bridge that restarted never queues behind its
    // own dead connection.
    for (;;) {
        int fd = accept(_listenFd, nullptr, nullptr);
        if (fd == -1) {
            break;
        }

        if (!prepare_fd(fd)) {
            ::close(fd);
            continue;
        }

        if (_clientFd != -1) {
            dropClient();
            events.disconnected = true;
        }

        _clientFd = fd;
        events.connected = true;
    }

    if (_clientFd == -1) {
        return events;
    }

    char buffer[65536];
    for (;;) {
        ssize_t count = recv(_clientFd, buffer, sizeof(buffer), 0);
        if (count > 0) {
            events.dropped += _input.append(buffer, static_cast<size_t>(count), lines);
            continue;
        }

        if (count == -1 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            break;
        }

        if (count == -1 && errno == EINTR) {
            continue;
        }

        // Orderly shutdown or a hard error: either way the client is gone.
        dropClient();
        events.disconnected = true;
        return events;
    }

    if (!flush()) {
        dropClient();
        events.disconnected = true;
    }

    return events;
}

bool SocketServer::send(const std::string& line)
{
    if (_clientFd == -1) {
        return false;
    }

    if (_output.size() + line.size() + 1 > kMaxPendingOutput) {
        // The client has stopped reading; holding on would only grow memory.
        dropClient();
        _lostClient = true;
        return false;
    }

    _output.append(line);
    _output.push_back('\n');

    if (!flush()) {
        dropClient();
        _lostClient = true;
        return false;
    }

    return true;
}

bool SocketServer::hasClient() const
{
    return _clientFd != -1;
}

void SocketServer::dropClient()
{
    if (_clientFd != -1) {
        ::close(_clientFd);
        _clientFd = -1;
    }
    _input.clear();
    _output.clear();
}

// Sends as much pending output as the socket takes. Returns false when the
// client is gone.
bool SocketServer::flush()
{
    size_t sent = 0;
    while (sent < _output.size()) {
        ssize_t count = ::send(_clientFd, _output.data() + sent, _output.size() - sent, kSendFlags);
        if (count > 0) {
            sent += static_cast<size_t>(count);
            continue;
        }

        if (count == -1 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            break;
        }

        if (count == -1 && errno == EINTR) {
            continue;
        }

        return false;
    }

    _output.erase(0, sent);
    return true;
}

#else

// Unix-domain sockets only; elsewhere MCP reports itself unavailable.

SocketServer::SocketServer()
    : _listenFd(-1)
    , _clientFd(-1)
    , _lostClient(false)
    , _input(kMaxLineLength)
{
}

SocketServer::~SocketServer()
{
}

bool SocketServer::listen(const std::string& path, std::string& error)
{
    error = "MCP needs Unix-domain sockets, which this platform build doesn't have";
    return false;
}

void SocketServer::close()
{
}

SocketEvents SocketServer::poll(std::vector<std::string>& lines)
{
    return SocketEvents();
}

bool SocketServer::send(const std::string& line)
{
    return false;
}

bool SocketServer::hasClient() const
{
    return false;
}

void SocketServer::dropClient()
{
}

bool SocketServer::flush()
{
    return false;
}

#endif

} // namespace fallout
