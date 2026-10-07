-- Test entry point: lua tests/run.lua [filter]
-- Runs every tests/*_test.lua file listed in tests/manifest.lua.

local scriptDir = arg[0]:match("^(.*)/[^/]+$") or "."
ROOT_DIR = scriptDir .. "/.."
HARNESS_DIR = scriptDir .. "/harness"

local Runner = dofile(HARNESS_DIR .. "/runner.lua")
local Loader = dofile(HARNESS_DIR .. "/loader.lua")

-- Test files see these as globals.
describe = Runner.describe
it = Runner.it
expect = Runner.expect
Harness = Loader

for _, file in ipairs(dofile(scriptDir .. "/manifest.lua")) do
	dofile(scriptDir .. "/" .. file)
end

local failures = Runner.Run(arg[1])
os.exit(failures == 0 and 0 or 1)
