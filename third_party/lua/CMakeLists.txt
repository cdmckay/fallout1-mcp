include(FetchContent)

# Lua ships no CMake build, so this fetches the release tarball and builds the
# library from its sources. The hash is the one published at lua.org/ftp.
FetchContent_Declare(lua
    URL "https://www.lua.org/ftp/lua-5.5.1.tar.gz"
    URL_HASH SHA256=1c4b4068d67061f2a2231ad2b5422e77acea1487ea9890f6320af614f4373dce
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
)

FetchContent_MakeAvailable(lua)

set(LUA_SOURCES
    lapi.c lcode.c lctype.c ldebug.c ldo.c ldump.c lfunc.c lgc.c llex.c lmem.c
    lobject.c lopcodes.c lparser.c lstate.c lstring.c ltable.c ltm.c lundump.c
    lvm.c lzio.c
    lauxlib.c lbaselib.c lcorolib.c ldblib.c liolib.c lmathlib.c loadlib.c
    loslib.c lstrlib.c ltablib.c lutf8lib.c linit.c
)
list(TRANSFORM LUA_SOURCES PREPEND "${lua_SOURCE_DIR}/src/")

add_library(lua STATIC ${LUA_SOURCES})
target_include_directories(lua PUBLIC "${lua_SOURCE_DIR}/src")

# POSIX only: the game never loads C modules, so there's no need for dlopen.
if(UNIX)
    target_compile_definitions(lua PRIVATE LUA_USE_POSIX)
    target_link_libraries(lua PUBLIC m)
endif()

add_library(lua::lua ALIAS lua)

# The stand-alone interpreter, built from the same sources so the Lua tests
# run against exactly the Lua the game embeds.
if(FALLOUT_MCP_TESTS)
    add_executable(lua_cli "${lua_SOURCE_DIR}/src/lua.c")
    target_link_libraries(lua_cli lua)
    set_target_properties(lua_cli PROPERTIES OUTPUT_NAME lua)
endif()
