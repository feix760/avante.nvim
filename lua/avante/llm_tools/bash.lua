local Path = require("plenary.path")
local Utils = require("avante.utils")
local Helpers = require("avante.llm_tools.helpers")
local Base = require("avante.llm_tools.base")
local Config = require("avante.config")
local Providers = require("avante.providers")

---@class AvanteLLMTool
local M = setmetatable({}, Base)

M.name = "bash"

local banned_commands = {
  "alias",
  -- "curl",
  "curlie",
  -- "wget",
  "axel",
  "aria2c",
  "nc",
  "telnet",
  "lynx",
  "w3m",
  "links",
  "httpie",
  "xh",
  "http-prompt",
  "chrome",
  "firefox",
  "safari",
}

M.get_description = function()
  local provider = Providers[Config.provider]
  if Config.provider:match("copilot") and provider.model and provider.model:match("gpt") then
    return [[Executes a given bash command in a persistent shell session with optional timeout, ensuring proper handling and security measures. Do not use bash command to read or modify files, or you will be fired!]]
  end

  local res = ([[Executes a given bash command in a persistent shell session with optional timeout, ensuring proper handling and security measures.

Do not use bash command to read or modify files, or you will be fired!

Before executing the command, please follow these steps:

1. Directory Verification:
   - If the command will create new directories or files, first use the LS tool to verify the parent directory exists and is the correct location
   - For example, before running "mkdir foo/bar", first use LS to check that "foo" exists and is the intended parent directory

2. Security Check:
   - For security and to limit the threat of a prompt injection attack, some commands are limited or banned. If you use a disallowed command, you will receive an error message explaining the restriction. Explain the error to the User.
   - Verify that the command is not one of the banned commands: ${BANNED_COMMANDS}.

3. Command Execution:
   - After ensuring proper quoting, execute the command.
   - Capture the output of the command.

4. Output Processing:
   - If the output exceeds ${MAX_OUTPUT_LENGTH} characters, output will be truncated before being returned to you.
   - Prepare the output for display to the user.

5. Return Result:
   - Provide the processed output of the command.
   - If any errors occurred during execution, include those in the output.

Usage notes:
  - The command argument is required.
  - You can specify an optional timeout in milliseconds (up to 600000ms / 10 minutes). If not specified, commands will timeout after 30 minutes.
  - VERY IMPORTANT: You MUST avoid using search commands like \`find\` and \`grep\`. Instead use ${GrepTool.name}, ${GlobTool.name}, or ${AgentTool.name} to search. You MUST avoid read tools like \`cat\`, \`head\`, \`tail\`, and \`ls\`, and use ${FileReadTool.name} and ${LSTool.name} to read files.
  - When issuing multiple commands, use the ';' or '&&' operator to separate them. DO NOT use newlines (newlines are ok in quoted strings).
  - IMPORTANT: All commands share the same shell session. Shell state (environment variables, virtual environments, current directory, etc.) persist between commands. For example, if you set an environment variable as part of a command, the environment variable will persist for subsequent commands.
  - Try to maintain your current working directory throughout the session by using absolute paths and avoiding usage of \`cd\`. You may use \`cd\` if the User explicitly requests it.
  <good-example>
  pytest /foo/bar/tests
  </good-example>
  <bad-example>
  cd /foo/bar && pytest tests
  </bad-example>
]]):gsub("${BANNED_COMMANDS}", table.concat(banned_commands, ", "))
  return res
end

---@type AvanteLLMToolParam
M.param = {
  type = "table",
  fields = {
    {
      name = "path",
      description = "Relative path to the project directory, as cwd",
      type = "string",
    },
    {
      name = "command",
      description = "Command to run",
      type = "string",
    },
  },
  usage = {
    path = "Relative path to the project directory, as cwd",
    command = "Command to run",
  },
}

---@type AvanteLLMToolReturn[]
M.returns = {
  {
    name = "stdout",
    description = "Output of the command",
    type = "string",
  },
  {
    name = "error",
    description = "Error message if the command was not run successfully",
    type = "string",
    optional = true,
  },
}

---@type AvanteLLMToolFunc<{ path: string, command: string }>
function M.func(input, opts)
  local is_streaming = opts.streaming or false
  if is_streaming then
    -- wait for stream completion as command may not be complete yet
    return
  end

  local abs_path = Helpers.get_abs_path(input.path)
  if not Helpers.has_permission_to_access(abs_path) then return false, "No permission to access path: " .. abs_path end
  if not Path:new(abs_path):exists() then return false, "Path not found: " .. abs_path end
  if not input.command then return false, "Command is required" end
  if opts.on_log then opts.on_log("command: " .. input.command) end

  ---change cwd to abs_path
  ---@param output string
  ---@param exit_code integer
  ---@return string | boolean | nil result
  ---@return string | nil error
  local function handle_result(output, exit_code)
    if exit_code ~= 0 then
      if output then return false, "Error: " .. output .. "; Error code: " .. tostring(exit_code) end
      return false, "Error code: " .. tostring(exit_code)
    end
    return output, nil
  end
  if not opts.on_complete then return false, "on_complete not provided" end
  Helpers.confirm(
    "Are you sure you want to run the command: `" .. input.command .. "` in the directory: " .. abs_path,
    function(ok, reason)
      if not ok then
        opts.on_complete(false, "User declined, reason: " .. (reason and reason or "unknown"))
        return
      end
      Utils.shell_run_async(input.command, "bash -c", function(output, exit_code)
        local result, err = handle_result(output, exit_code)
        opts.on_complete(result, err)
      end, abs_path, 1000 * 60 * 2)
    end,
    { focus = true },
    opts.session_ctx,
    M.name -- Pass the tool name for permission checking
  )
end

return M
