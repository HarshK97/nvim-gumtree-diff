local top_down = require("diffmantic.core.top_down")
local bottom_up = require("diffmantic.core.bottom_up")
local recovery = require("diffmantic.core.recovery")
local actions = require("diffmantic.core.actions")

local M = {}

M.top_down_match = top_down.top_down_match
M.bottom_up_match = bottom_up.bottom_up_match
M.recovery_match = recovery.recovery_match
M.generate_actions = actions.generate_actions

return M
