local Utils = require("avante.utils")

local M = {}

local chat_id = nil;

function M.new_chat_id()
  -- 2133d35c17761635479798037e0ccf
  -- avante1776164386d3356a5741ba10
  chat_id = 'avante' .. os.time() .. string.format("%014x", math.random(0, 0xffffffffffffff))
end

M.new_chat_id()

function M.get_chat_id()
  return chat_id
end

return M
