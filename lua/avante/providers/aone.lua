local Utils = require("avante.utils")
local Config = require("avante.config")
local Clipboard = require("avante.clipboard")
local Providers = require("avante.providers")
local HistoryMessage = require("avante.history.message")
local ReActParser = require("avante.libs.ReAct_parser2")
local JsonParser = require("avante.libs.jsonparser")
local Prompts = require("avante.utils.prompts")
local LlmTools = require("avante.llm_tools")

local P = require("avante.providers")

---@class AvanteProviderFunctor
local M = {}

M.api_key_name = "AONE_AUTHORIZATION"

M.role_map = {
  user = "user",
  assistant = "assistant",
}

function M:is_disable_stream() return false end

local idGen = 0
function nextId()
  idGen = idGen + 1
  return ''..idGen
end

-- SSE 流解析状态
local buffer = ""
local in_tool_use = false
local tool_use_content = ""
local usage = nil

function M:reset_parse_response()
  buffer = ""
  in_tool_use = false
  tool_use_content = ""
  usage = nil
end

function M:finish_pending_messages(ctx, opts)
  if ctx.tool_use_map then
    for _, tool_use in pairs(ctx.tool_use_map) do
      if tool_use.state == "generating" then self:add_tool_use_message(ctx, tool_use, "generated", opts) end
    end
  end
end

function M:add_tool_use_message(ctx, tool_use, state, opts)
  local msg = HistoryMessage:new("assistant", {
    type = "tool_use",
    name = tool_use.name,
    id = tool_use.id,
    input = tool_use.input,
  }, {
    state = state,
    uuid = tool_use.uuid,
    turn_id = ctx.turn_id,
  })
  tool_use.uuid = msg.uuid
  tool_use.state = state

  ctx.tool_use_map = ctx.tool_use_map or {}
  ctx.tool_use_map[tool_use.id] = tool_use

  Utils.debug('add tool use', tool_use.name, state, tool_use.uuid)
  if opts.on_messages_add then opts.on_messages_add({ msg }) end
  if state == "generating" then opts.on_stop({ reason = "tool_use", streaming_tool_use = true }) end
end

function M:add_text_message(ctx, content, state, opts)
  local msg = HistoryMessage:new("assistant", content, {
    state = state,
    turn_id = ctx.turn_id,
  })
  if opts.on_messages_add then opts.on_messages_add({ msg }) end
end

function M:handle_lines(ctx, opts, lines)
  for _, line in ipairs(lines) do
    -- 检查是否是 tool_use 开始标签
    if line:match("^%s*<tool_use>%s*$") then
      in_tool_use = true
      tool_use_content = ""
    -- 检查是否是 tool_use 结束标签
    elseif line:match("^%s*</tool_use>%s*$") then
      if in_tool_use then
        -- 解析 tool_use 内容
        local tool_use_json = tool_use_content:gsub("^%s+", ""):gsub("%s+$", "")
        if tool_use_json ~= "" then
          local jsn = vim.json.decode(tool_use_json)
          jsn.id = jsn.id or nextId()
          self:finish_pending_messages(ctx, opts)
          self:add_tool_use_message(ctx, jsn, 'generating', opts)
        else
          opts.on_stop({ reason = "error", error = "Empty tool_use content" })
        end
        -- 重置状态
        in_tool_use = false
        tool_use_content = ""
      end
    elseif in_tool_use then
      if tool_use_content == "" then
        tool_use_content = line
      else
        tool_use_content = tool_use_content .. "\n" .. line
      end
    else
      if line ~= "" then
        self:finish_pending_messages(ctx, opts)
        self:add_text_message(ctx, line, "generated", opts)
      end
    end
  end
end

function M:mock(ctx, opts)
  local res = [[
  我需要在 playwright.config.ts 文件中导入 fs 模块。让我先查看当前的导入语句，然后添加 fs 模块的导入。

  <tool_use>
  {"name": "str_replace", "input": {"path": "playwright.config.ts", "old_str": "import path from 'path';\nimport type { PlaywrightTestConfig } from '@playwright/test';\nimport { devices } from '@playwright/test';", "new_str": "import fs from 'fs';\nimport path from 'path';\nimport type { PlaywrightTestConfig } from '@playwright/test';\nimport { devices } from '@playwright/test';"}}
  </tool_use>

  已成功在 playwright.config.ts 文件中导入了 fs 模块。fs 模块已添加到文件顶部的导入语句中，位置在 path 模块之前，这样可以保持良好的代码组织结构。

  <tool_use>
  {"name": "attempt_completion", "input": {"result": "已成功在 playwright.config.ts 文件中导入 fs 模块。fs 模块现在可以在配置文件中使用，用于文件系统相关的操作。"}}
  </tool_use>
  ]]

  local lines = vim.split(res, "\n")

  handle_lines(ctx, opts, lines)
end

function M:parse_response(ctx, data_stream, _, opts)
  -- 检查是否是流结束标志
  if data_stream == "[DONE]" then
    -- self:mock(ctx, opts)
    self:finish_pending_messages(ctx, opts)
    if ctx.tool_use_map and vim.tbl_count(ctx.tool_use_map) > 0 then
      ctx.tool_use_map = {}
      opts.on_stop({ reason = "tool_use", usage = usage })
    else
      opts.on_stop({ reason = "complete", usage = usage })
    end
    self:reset_parse_response()
    return
  end

  -- if type(data_stream) == "string" then return end

  -- 解析 JSON
  local json = vim.json.decode(data_stream)

  if json.usage then
    usage = json.usage
  end

  local lines = {}

  if json.content then
    buffer = buffer .. json.content
    lines = vim.split(buffer, "\n")
    -- 保留最后一行（可能不完整）
    local incomplete_line = table.remove(lines)
    buffer = incomplete_line
  elseif buffer ~= "" then
    table.insert(lines, buffer)
    buffer = ""
  end

  handle_lines(ctx, opts, lines)
end

local chat_id = ''

function M:parse_curl_args(prompt_opts)
  local provider_conf, request_body = Providers.parse_config(self)

  local headers = {
    ["Content-Type"] = "application/json",
    ["x-model-name"] = "ide-idealab/" .. provider_conf.model,
    ["x-client-type"] = "Visual Studio Code",
    ["x-client-version"] = "1.107.1",
    ["x-plugin-version"] = "3.2.48"
  }

  if Providers.env.require_api_key(provider_conf) then
    local api_key = Providers.env.parse_envvar(self)
    if api_key == nil then
      Utils.error(Config.provider .. ": API key is not set, please set it in your environment variable or config file")
      return nil
    end
    headers["Authorization"] = "Bearer " .. api_key
  end

  -- Determine endpoint path based on use_response_api
  local endpoint_path = "/v1/chat"

  local messages = {
    {
      role = "system",
      content = Prompts.get_ReAct_system_prompt(provider_conf, prompt_opts),
    },
    {
      aone_copilot_message_type= "claude_cache_control_message",
      content = { {
        cache_control = {
          ttl= "1h",
          type = "ephemeral",
        },
        text= "以上就是你的设定，你要遵守上述设定，然后按照用户的设定和需求进行工作。",
        type= "text",
      } },
      role = "user",
    },
    {
      aone_copilot_message_type = "user_query",
      content = { {
        cache_control = {
          type = "ephemeral"
        },
        text = table.concat({
          prompt_opts.messages[1].content,
          '以上是用户希望你直接阅读和编辑的内容（如果代码已提供，无需重复使用 view 等工具读取内容）',
          prompt_opts.messages[2].content,
        }, "\n"),
        type = "text"
      }},
      role = "user"
    },
  }

  local idx = 0
  local assistant = {}
  local add_assistant = function()
    if #assistant > 0 then
      table.insert(messages, { role = "assistant", content = table.concat(assistant, "\n") })
      assistant = {}
    end
  end

  vim
    .iter(prompt_opts.messages)
    :each(function(msg)
      idx = idx + 1
      if idx <= 2 then return end

      if type(msg.content) == "string" then
        if msg.role == 'assistant' then
          table.insert(assistant, msg.content)
          return
        end
        add_assistant()
        table.insert(messages, { role = msg.role, content = msg.content })
      elseif type(msg.content) == "table" then
        add_assistant()

        if #msg.content == 1 then
          local obj = msg.content[1]
          local content = ''
          if obj.type == 'tool_use' then
            content = '<tool_use>\n' .. vim.json.encode({
              name = obj.name,
              input = obj.input,
              id = obj.id,
            }) .. '\n</tool_use>'
          elseif obj.type == 'tool_result' then
            content = '<tool_result>\n' .. vim.json.encode({
              tool_use_id = obj.tool_use_id,
              is_error = obj.is_error,
              content = obj.content,
              is_user_declined = obj.is_user_declined,
            }) .. '\n</tool_result>'
          else
            content = vim.json.encode(obj)
          end
          table.insert(messages, {
            role = msg.role,
            content = content,
          })
        else
          table.insert(messages, { role = msg.role, content = vim.json.encode(msg.content) })
        end
      end
    end)

  -- 开始的时候 messages 长度 2
  if #prompt_opts.messages <= 2 then
    chat_id = os.time() .. '-' .. string.format("%04x", math.random(0, 0xffff))
  end

  local base_body = {
    needAppend = false,
    chatMessage = messages,
    extraConfigs = {
      chat_id = chat_id,
    },
  }

  return {
    url =  Utils.url_join(provider_conf.endpoint, endpoint_path),
    proxy = provider_conf.proxy,
    insecure = provider_conf.allow_insecure,
    headers = Utils.tbl_override(headers, self.extra_headers),
    body = base_body,
  }
end

return M
