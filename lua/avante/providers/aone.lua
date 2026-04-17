local Utils = require("avante.utils")
local Path = require("avante.path")
local Config = require("avante.config")
local Clipboard = require("avante.clipboard")
local Providers = require("avante.providers")
local HistoryMessage = require("avante.history.message")
local ReActParser = require("avante.libs.ReAct_parser2")
local JsonParser = require("avante.libs.jsonparser")
local Prompts = require("avante.utils.prompts")
local LlmTools = require("avante.llm_tools")
local Skill = require("avante.skill")

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
local text_contents = {}
local usage = nil

function M:reset_parse_response()
  buffer = ""
  in_tool_use = false
  tool_use_content = ""
  text_contents = {}
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

function M:clear_text_contents(ctx, opts)
  Utils.debug('clear text contents', text_contents);
  if #text_contents > 0 then
    self:add_text_message(ctx, table.concat(text_contents, '\n'), "generated", opts)
  end
  text_contents = {}
end

function M:handle_lines(ctx, opts, lines)
  for _, line in ipairs(lines) do
    -- 检查是否是 tool_use 开始标签
    if line:match("^%s*<tool_use%s*([^>]*)>%s*$") then
      in_tool_use = true
      tool_use_content = ""
      self:clear_text_contents(ctx, opts)
    -- 检查是否是 tool_use 结束标签
    elseif line:match("^%s*</tool_use>%s*$") then
      if in_tool_use then
        -- 解析 tool_use 内容
        local tool_use_json = tool_use_content:gsub("^%s+", ""):gsub("%s+$", "")
        if tool_use_json ~= "" then
          local ok, jsn = pcall(vim.json.decode, tool_use_json)

          if not ok then
            local repaired_json = Utils.repair_json(tool_use_json)
            local repair_ok, repair_jsn = pcall(vim.json.decode, repaired_json)
            if repair_ok then
              ok = repair_ok
              jsn = repair_jsn
            end
          end

          if ok then
            jsn.id = jsn.id or nextId()
            self:finish_pending_messages(ctx, opts)
            self:add_tool_use_message(ctx, jsn, 'generating', opts)
          else
            opts.on_stop({ reason = "error", error = "Invalid tool_use content " .. tool_use_json })
          end
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
        table.insert(text_contents, line)
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

  self:handle_lines(ctx, opts, lines)
end

function M:parse_response(ctx, data_stream, _, opts)
  -- 检查是否是流结束标志
  if data_stream == "[DONE]" then
    if buffer ~= "" then
      self:handle_lines(ctx, opts, { buffer })
      buffer = ""
    end
    self:clear_text_contents(ctx, opts)

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

  local content = nil
  if json.choices and json.choices[1] and json.choices[1].delta then
    content = json.choices[1].delta.content
  elseif json.content then
    content = json.content
  end

  local lines = {}
  if content then
    if opts.on_chunk then opts.on_chunk(content) end
    buffer = buffer .. content
    lines = vim.split(buffer, "\n")
    -- 保留最后一行（可能不完整）
    local incomplete_line = table.remove(lines)
    buffer = incomplete_line
  elseif buffer ~= "" then
    table.insert(lines, buffer)
    buffer = ""
  end

  self:handle_lines(ctx, opts, lines)
end

local function ls_dir(path, get_sub)
  local files = {}
  local dir = vim.loop.fs_scandir(path)
  if not dir then
    return nil, "Directory not found or not accessible: " .. tostring(path)
  end

  local format_path = function(name, type)
    if type == "directory" then
      return name .. "/"
    end
    return name
  end

  while true do
    local name, type = vim.loop.fs_scandir_next(dir)
    if not name then break end
    if type == "directory" and get_sub ~= 0 and name ~= '.git' and name ~= 'node_modules' then
      local sub_files = ls_dir(path .. "/" .. name, 0)
      if #sub_files < 50 then
        for _, sub_name in ipairs(sub_files) do
          table.insert(files, name .. "/" .. sub_name)
        end
      else
        table.insert(files, format_path(name, type))
      end
    else
      table.insert(files, format_path(name, type))
    end
  end
  return files
end

local start_data = {
  chat_id = '',
  root_files = nil,
  core_files = nil,
  system_prompt = '',
  project_root = '',
  repo_type = '',
  repo = '',
}

local function init_start_data(prompt_opts)
  local project_root = Utils.root.get()

  -- 2133d35c17761635479798037e0ccf
  -- avante1776164386d3356a5741ba10
  chat_id = 'avante' .. os.time() .. string.format("%014x", math.random(0, 0xffffffffffffff))

  root_files = ls_dir(project_root)

  local tools = {}
  for _, tool in ipairs(prompt_opts.tools) do
    local description = tool.description
    if tool.get_description then
      description = tool:get_description()
    end
    local input = {}
    for _, field in ipairs(tool.param.fields) do
      local desc = field.description
      if field.get_description then
        desc = field:get_description()
      end
      table.insert(input, {
        name = field.name,
        type = field.type,
        items = field.items,
        description = desc,
      })
    end
    table.insert(tools, '<tool>\n'..vim.json.encode({
      name = tool.name,
      description = description,
      input = input,
      returns = tool.returns,
    })..'\n</tool>')
  end

  local hub = require("mcphub").get_hub_instance()
  local mcp = hub and hub:get_active_servers_prompt() or ""

  local skills = Skill.get_skills()

  local system_prompt = Path.prompts.render_file("aone.avanterules", {
    ask = true,
    code_lang = '',
    tools = table.concat(tools, "\n"),
    mcp = mcp,
    skills = skills
  })

  local repo = ''
  local repo_type = ''
  -- 尝试读取 project_root 下的 .git/config 获取仓库地址
  if vim.loop.fs_stat(project_root .. "/.git/config") then
    local git_config = vim.fn.readfile(project_root .. "/.git/config")
    for _, line in ipairs(git_config) do
      if line:match("^%s*url%s*=%s*(.+)$") then
        repo = line:match("^%s*url%s*=%s*(.+)$")
        repo_type = 'git'
        break
      end
    end
  end

  local core_files = {}
  -- 尝试读取 project_root 下的 package.json、README.md 获取依赖
  for _, file in ipairs({ 'package.json' }) do
    -- 如果文件大小小于 10kb
    if vim.loop.fs_stat(project_root .. "/" .. file) and vim.loop.fs_stat(project_root .. "/" .. file).size < 10 * 1024 then
      local content = vim.fn.readfile(project_root .. "/" .. file)
      table.insert(core_files, table.concat({
        '<file path="' .. file .. '">',
        table.concat(content, '\n'),
        '</file>',
      }, '\n'))
    end
  end

  start_data = {
    project_root = project_root,
    chat_id = chat_id,
    root_files = root_files,
    core_files = core_files,
    system_prompt = system_prompt,
    repo_type = repo_type,
    repo = repo,
  }
end

function M:parse_curl_args(prompt_opts)
  local provider_conf, request_body = Providers.parse_config(self)

  local is_normal = prompt_opts.tools and #prompt_opts.tools > 0
  -- 开始的时候 messages 长度 2
  if #prompt_opts.messages <= 2 and is_normal and not prompt_opts.memory then
    init_start_data(prompt_opts)
  end

  local chat_id = start_data.chat_id
  local project_root = start_data.project_root
  local root_files = start_data.root_files
  local core_files = start_data.core_files
  local system_prompt = start_data.system_prompt
  local repo_type = start_data.repo_type
  local repo = start_data.repo

  local is_openai = not provider_conf.endpoint:match("ducky.code")

  local endpoint_path = "/v1/chat"
  local headers = {
    ["Content-Type"] = "application/json",
    ["x-model-name"] = "ide-idealab/" .. provider_conf.model,
    ["x-client-type"] = "Visual Studio Code",
    ["x-client-version"] = "1.107.1",
    ["x-plugin-version"] = "3.2.48",
    ["x-idealab-session-id"] = chat_id,
    ["x-session-id"] = chat_id,
    ["x-git-repos"] = repo,
  }

  if is_openai then
    endpoint_path = "/chat/completions"
    headers = {
      ["Content-Type"] = "application/json",
      ["x-idealab-session-id"] = chat_id,
      ["x-session-id"] = chat_id,
    }
  end

  if Providers.env.require_api_key(provider_conf) then
    local api_key = Providers.env.parse_envvar(self)
    if api_key == nil then
      Utils.error(Config.provider .. ": API key is not set, please set it in your environment variable or config file")
      return nil
    end
    headers["Authorization"] = "Bearer " .. api_key
  end

  local system_info = {
    system_data = vim.uv.os_uname().sysname,
    shell = os.getenv("SHELL"),
    project_root = project_root,
    repo_type = repo_type,
    repo = repo,
    agent_type = '当前你正处于 Agent 模式',
  }

  local messages = {
    {
      role = "system",
      content = system_prompt,
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
  }

  if is_openai then
    messages = {
      {
        role = "system",
        content = system_prompt,
      },
    }
  end

  if not is_normal then
    messages = {
      {
        role = "system",
        content = prompt_opts.system_prompt,
      },
    }
  end

  local assistant = {}
  local add_assistant = function()
    if #assistant > 0 then
      table.insert(messages, { role = "assistant", content = table.concat(assistant, "\n") })
      assistant = {}
    end
  end

  local add_message = function(msg)
    add_assistant()
    table.insert(messages, msg)
  end

  local idx = 0
  local last_user_query_idx = 0
  vim
    .iter(prompt_opts.messages)
    :each(function(msg)
      idx = idx + 1
      if type(msg.content) == "string"  and msg.role == 'user' and msg.content:match("^<task>") then
        last_user_query_idx = idx
      end
    end)

  idx = 0
  local context_message = ''
  local has_set_environment = false
  local env_message = table.concat({
    '<environment>',
    '<system_info>',
    vim.json.encode(system_info),
    '/<system_info>',
    '<project_structure>',
    vim.json.encode(root_files),
    '</project_structure>',
    '以上是会话初期的部分文件结构，不是最新的，仅供参考，如需查看最新文件结构，请使用相关工具。',
    '<project_core_files>',
    table.concat(core_files, "\n"),
    '</project_core_files>',
    '</environment>',
  }, "\n")
  vim
    .iter(prompt_opts.messages)
    :each(function(msg)
      idx = idx + 1

      if msg.is_context then
        if msg.content then
          if msg.content:match("^<memory>") then
            context_message = msg.content
          else
            context_message = table.concat({
              '<additional_data>',
              msg.content,
              '以上是用户希望你直接阅读和编辑的内容（如果文件内容已提供，无需重复使用 view 等工具读取内容）',
              '/<additional_data>',
            }, "\n")
          end
        end
        return
      end

      if type(msg.content) == "string" then
        if msg.role == 'user' and msg.content:match("^<task>") then
          local contents = {}
          if has_set_environment == false then
            has_set_environment = true
            table.insert(contents, env_message)
          end
          if idx == last_user_query_idx then
            table.insert(contents, context_message)
            context_message = '';
          end
          table.insert(contents, msg.content)
          add_message({
            aone_copilot_message_type = "user_query",
            content = { {
              cache_control = {
                type = "ephemeral"
              },
              text = table.concat(contents, "\n\n"),
              type = "text"
            }},
            role = "user"
          })
          return
        end

        if msg.role == 'assistant' then
          table.insert(assistant, msg.content)
          return
        end
        add_message({ role = msg.role, content = msg.content })
      elseif type(msg.content) == "table" then
        if #msg.content == 1 then
          local obj = msg.content[1]
          local content = ''
          if obj.type == 'tool_use' then
            content = '<tool_use json_validate="true">\n' .. vim.json.encode({
              name = obj.name,
              input = obj.input,
              id = obj.id,
            }) .. '\n</tool_use>'
          elseif obj.type == 'tool_result' then
            content = { {
              text = '<tool_result>\n' .. vim.json.encode({
                tool_use_id = obj.tool_use_id,
                is_error = obj.is_error,
                content = obj.content,
                is_user_declined = obj.is_user_declined,
              }) .. '\n</tool_result>',
              type = "text",
            } }
            add_message({
              role = msg.role,
              content = content,
              aone_copilot_message_type = 'tool_result',
            })
            return
          else
            content = vim.json.encode(obj)
          end

          if msg.role == 'assistant' then
            table.insert(assistant, content)
            return
          end

          add_message({ role = msg.role, content = content })
        else
          add_message({ role = msg.role, content = vim.json.encode(msg.content) })
        end
      end
    end)

  if context_message ~= '' then
    add_message({
      content = { {
        cache_control = {
          type = "ephemeral"
        },
        text = env_message .. "\n\n" .. context_message,
        type = "text"
      }},
      role = "user"
    })
  end

  add_assistant()

  local base_body = {
    needAppend = false,
    chatMessage = messages,
    extraConfigs = {
      chat_id = chat_id,
    },
  }

  if is_openai then
    for _, msg in ipairs(messages) do
      if type(msg.content) ~= "string" then
        msg.content = msg.content[1].text
      end
    end
    base_body = {
      messages = messages,
      stream = true,
      stream_options = {
        include_usage = true,
      },
      model = provider_conf.model,
      temperature = 0.75,
    }
  end

  return {
    url =  Utils.url_join(provider_conf.endpoint, endpoint_path),
    -- url =  Utils.url_join(provider_conf.endpoint, endpoint_path .. '/404'),
    proxy = provider_conf.proxy,
    -- proxy = 'http://127.0.0.1:8080',
    insecure = provider_conf.allow_insecure,
    headers = Utils.tbl_override(headers, self.extra_headers),
    body = base_body,
  }
end

return M
