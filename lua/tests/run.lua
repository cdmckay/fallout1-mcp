-- Runs the Lua unit tests. Use the interpreter built from the game's own Lua
-- (cmake -DFALLOUT_MCP_TESTS=ON), so the tests see exactly that version:
--
--   build/third_party/lua/lua lua/tests/run.lua
--
-- ctest runs this too. Each test file returns a table of test functions.

local root = arg[0]:match("^(.*)/tests/run%.lua$") or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local files = {
    "tests.character_test",
    "tests.combat_test",
    "tests.core_test",
    "tests.input_test",
    "tests.inventory_test",
    "tests.movement_test",
    "tests.state_test",
    "tests.survey_test",
}

local passed, failed = 0, 0

for _, file in ipairs(files) do
    local tests = require(file)

    local names = {}
    for name in pairs(tests) do
        names[#names + 1] = name
    end
    table.sort(names)

    for _, name in ipairs(names) do
        local ok, err = xpcall(tests[name], debug.traceback)
        if ok then
            passed = passed + 1
        else
            failed = failed + 1
            io.stderr:write(("FAIL %s %s\n%s\n"):format(file, name, err))
        end
    end
end

print(("%s: %d passed, %d failed"):format(_VERSION, passed, failed))
os.exit(failed == 0 and 0 or 1)
