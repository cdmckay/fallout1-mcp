#include "mcp/socket_server.h"

#include <catch2/catch_test_macros.hpp>

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

#include <string>
#include <vector>

using fallout::SocketEvents;
using fallout::SocketServer;

namespace {

// A private directory for one test's socket, removed afterwards. Kept short:
// socket paths are limited to about 100 bytes.
struct TempDir {
    std::string path;

    TempDir()
    {
        char pattern[] = "/tmp/fo-mcp-XXXXXX";
        REQUIRE(mkdtemp(pattern) != nullptr);
        path = pattern;
    }

    ~TempDir()
    {
        std::string socket = path + "/game.sock";
        unlink(socket.c_str());
        rmdir(path.c_str());
    }

    std::string socket() const
    {
        return path + "/game.sock";
    }
};

int connect_to(const std::string& path)
{
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    REQUIRE(fd != -1);

    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    strncpy(address.sun_path, path.c_str(), sizeof(address.sun_path) - 1);

    REQUIRE(connect(fd, reinterpret_cast<struct sockaddr*>(&address), sizeof(address)) == 0);
    return fd;
}

void write_all(int fd, const std::string& data)
{
    REQUIRE(write(fd, data.data(), data.size()) == static_cast<ssize_t>(data.size()));
}

// Reads from `fd` until `count` newline-terminated lines have arrived.
std::string read_lines(int fd, int count)
{
    std::string data;
    int seen = 0;
    while (seen < count) {
        char buffer[4096];
        ssize_t n = read(fd, buffer, sizeof(buffer));
        REQUIRE(n > 0);
        for (ssize_t i = 0; i < n; i++) {
            if (buffer[i] == '\n') {
                seen++;
            }
        }
        data.append(buffer, n);
    }
    return data;
}

} // namespace

TEST_CASE("SocketServer creates an owner-only socket")
{
    TempDir dir;
    SocketServer server;
    std::string error;

    REQUIRE(server.listen(dir.socket(), error));

    struct stat st;
    REQUIRE(stat(dir.socket().c_str(), &st) == 0);
    REQUIRE(S_ISSOCK(st.st_mode));
    REQUIRE((st.st_mode & 0777) == 0600);
}

TEST_CASE("SocketServer accepts a client and reads its lines")
{
    TempDir dir;
    SocketServer server;
    std::string error;
    REQUIRE(server.listen(dir.socket(), error));

    int client = connect_to(dir.socket());
    write_all(client, "{\"id\":1}\n{\"id\"");

    std::vector<std::string> lines;
    SocketEvents events = server.poll(lines);
    REQUIRE(events.connected);
    REQUIRE(server.hasClient());
    REQUIRE(lines == std::vector<std::string> { "{\"id\":1}" });

    write_all(client, ":2}\n");
    lines.clear();
    events = server.poll(lines);
    REQUIRE_FALSE(events.connected);
    REQUIRE(lines == std::vector<std::string> { "{\"id\":2}" });

    close(client);
}

TEST_CASE("SocketServer sends newline-terminated replies")
{
    TempDir dir;
    SocketServer server;
    std::string error;
    REQUIRE(server.listen(dir.socket(), error));

    int client = connect_to(dir.socket());
    std::vector<std::string> lines;
    server.poll(lines);

    REQUIRE(server.send("{\"id\":1,\"result\":{}}"));
    REQUIRE(server.send("{\"id\":2,\"result\":{}}"));

    REQUIRE(read_lines(client, 2) == "{\"id\":1,\"result\":{}}\n{\"id\":2,\"result\":{}}\n");

    close(client);
}

TEST_CASE("SocketServer delivers a reply larger than the socket buffer across polls")
{
    TempDir dir;
    SocketServer server;
    std::string error;
    REQUIRE(server.listen(dir.socket(), error));

    int client = connect_to(dir.socket());
    std::vector<std::string> lines;
    server.poll(lines);

    // About the size of a base64 screenshot.
    std::string big(2 * 1024 * 1024, 'x');
    REQUIRE(server.send(big));

    std::string received;
    fcntl(client, F_SETFL, fcntl(client, F_GETFL, 0) | O_NONBLOCK);
    for (int attempt = 0; attempt < 10000 && received.size() < big.size() + 1; attempt++) {
        char buffer[65536];
        ssize_t n = read(client, buffer, sizeof(buffer));
        if (n > 0) {
            received.append(buffer, n);
        }
        server.poll(lines);
    }

    REQUIRE(received.size() == big.size() + 1);
    REQUIRE(received.back() == '\n');

    close(client);
}

TEST_CASE("SocketServer reports a client that went away")
{
    TempDir dir;
    SocketServer server;
    std::string error;
    REQUIRE(server.listen(dir.socket(), error));

    int client = connect_to(dir.socket());
    std::vector<std::string> lines;
    server.poll(lines);
    close(client);

    SocketEvents events = server.poll(lines);
    REQUIRE(events.disconnected);
    REQUIRE_FALSE(server.hasClient());
    REQUIRE_FALSE(server.send("nobody is listening"));
}

TEST_CASE("SocketServer lets a new client replace the old one")
{
    TempDir dir;
    SocketServer server;
    std::string error;
    REQUIRE(server.listen(dir.socket(), error));

    int first = connect_to(dir.socket());
    std::vector<std::string> lines;
    server.poll(lines);

    int second = connect_to(dir.socket());
    write_all(second, "from second\n");
    SocketEvents events = server.poll(lines);

    REQUIRE(events.disconnected);
    REQUIRE(events.connected);
    REQUIRE(lines == std::vector<std::string> { "from second" });

    // The first client sees its connection closed.
    char byte;
    REQUIRE(read(first, &byte, 1) == 0);

    close(first);
    close(second);
}

TEST_CASE("SocketServer replaces a stale socket but not a live one")
{
    TempDir dir;
    std::string error;

    {
        SocketServer live;
        REQUIRE(live.listen(dir.socket(), error));

        SocketServer rival;
        REQUIRE_FALSE(rival.listen(dir.socket(), error));
        REQUIRE(error.find("already listening") != std::string::npos);
    }

    // Leave a stale socket file behind, as a crashed game would.
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    strncpy(address.sun_path, dir.socket().c_str(), sizeof(address.sun_path) - 1);
    REQUIRE(bind(fd, reinterpret_cast<struct sockaddr*>(&address), sizeof(address)) == 0);
    close(fd);

    SocketServer server;
    REQUIRE(server.listen(dir.socket(), error));
}

TEST_CASE("SocketServer won't replace a file that isn't a socket")
{
    TempDir dir;
    int fd = open(dir.socket().c_str(), O_CREAT | O_WRONLY, 0600);
    REQUIRE(fd != -1);
    close(fd);

    SocketServer server;
    std::string error;
    REQUIRE_FALSE(server.listen(dir.socket(), error));
    REQUIRE(error.find("isn't a socket") != std::string::npos);
}

TEST_CASE("SocketServer close removes the socket file")
{
    TempDir dir;
    SocketServer server;
    std::string error;
    REQUIRE(server.listen(dir.socket(), error));

    server.close();

    REQUIRE(access(dir.socket().c_str(), F_OK) == -1);
}
