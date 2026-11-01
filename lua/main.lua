-- The entry point the engine runs: the protocol core with every tool loaded.
local core = require("mcp.core")
require("tools")(core)
return core
