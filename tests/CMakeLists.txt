include(FetchContent)

FetchContent_Declare(Catch2
    URL "https://github.com/catchorg/Catch2/archive/refs/tags/v3.16.1.tar.gz"
    URL_HASH SHA256=d16bd1b8b2364918bd472cb216394acb93bde6784890df0d91bccfb3f28d777d
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
)

FetchContent_MakeAvailable(Catch2)

# The MCP pieces that don't need the engine, so they're tested on their own.
add_executable(mcp_tests
    "mcp/line_buffer_test.cc"
    "mcp/lua_host_test.cc"
    "mcp/message_log_test.cc"
    "mcp/png_test.cc"
    "mcp/scaled_clock_test.cc"
    "mcp/socket_server_test.cc"
    "${CMAKE_SOURCE_DIR}/src/mcp/line_buffer.cc"
    "${CMAKE_SOURCE_DIR}/src/mcp/lua_host.cc"
    "${CMAKE_SOURCE_DIR}/src/mcp/message_log.cc"
    "${CMAKE_SOURCE_DIR}/src/mcp/png.cc"
    "${CMAKE_SOURCE_DIR}/src/mcp/socket_server.cc"
)

target_include_directories(mcp_tests PRIVATE "${CMAKE_SOURCE_DIR}/src" ${SDL2_INCLUDE_DIRS})
target_link_libraries(mcp_tests PRIVATE Catch2::Catch2WithMain lua::lua stb::stb ${SDL2_LIBRARIES})
target_compile_definitions(mcp_tests PRIVATE MCP_LUA_DIR="${CMAKE_SOURCE_DIR}/lua")

list(APPEND CMAKE_MODULE_PATH "${catch2_SOURCE_DIR}/extras")
include(Catch)
catch_discover_tests(mcp_tests)

add_test(NAME lua COMMAND lua_cli "${CMAKE_SOURCE_DIR}/lua/tests/run.lua")
