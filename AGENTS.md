# AGENTS.md

> 面向 **AI 代码代理** 与 **新贡献者** 的工程说明书。
> 仅聚焦 `lua/` 目录 —— 即 avante.nvim 的全部 Lua 运行时实现。
> 配套 Rust 后端见根目录 `crates/`，本文不展开。

---

## 1. 项目定位

avante.nvim 是一个把 Neovim 改造为 **类 Cursor / Cline AI IDE** 的插件，提供：

- 持久化多轮聊天侧边栏（Sidebar）
- 行内 Edit 与代码块 Diff 合并
- 内联 Auto-Suggestion（Copilot Ghost-Text 风格）
- **Agentic Tool Use**：模型自主调用 ls/grep/glob/bash/edit_file/web_search/git_commit … 等 30+ 工具
- 多 Provider 抽象：Claude / OpenAI / Gemini / Azure / Bedrock / Vertex / Ollama / Copilot / Cohere / WatsonX / Aone / aClaude …
- ACP（Agent Client Protocol）外部 Agent 接入（Claude-Code / Gemini-CLI 等）
- RAG 服务、Repo Map（基于 tree-sitter，Rust 编写）、Web Search、PKCE OAuth

`lua/` 是所有上层逻辑的入口；Rust crates 仅作为 native 动态库（`avante_repo_map`、`avante_html2md`、`avante_tokenizers` …）通过 `require("avante_lib").load()` 注入 `package.cpath`。

---

## 2. 顶层布局

```
lua/
├── avante/                ← 插件主模块（几乎所有业务逻辑）
├── avante_lib.lua         ← 加载 build/ 下的 Rust 动态库（.so/.dylib/.dll）
└── cmp_avante/            ← 给 nvim-cmp 注册的补全源
    ├── commands.lua       ← /commands 补全
    ├── mentions.lua       ← @mentions 补全（codebase/diagnostics/file/…）
    └── shortcuts.lua      ← #shortcut 补全
```

```
lua/avante/
├── init.lua               (580)   插件主入口、Sidebar/Selection/Suggestion 注册、autocmds、keymaps、ACP 客户端注册表
├── api.lua                (335)   公开给用户的高级 API：ask/edit/refresh/focus/build/select_model/select_history/stop …
├── config.lua            (1122)   全部默认配置 + setup/override
├── llm.lua               (2207)   ★ 与模型交互的核心：curl 调用、流式解析、tool-use 调度、记忆压缩、ACP 桥接
├── sidebar.lua           (3527)   ★ 侧边栏 UI（result/input/selected_code/selected_files/todos 五容器）
├── selection.lua          (396)   可视模式选区 → Edit/Ask 浮窗
├── suggestion.lua         (630)   Auto-suggestion（ghost-text）：节流/去抖、多候选切换
├── diff.lua               (610)   冲突标记解析、ours/theirs/both/cursor 选择、跳转
├── file_selector.lua      (330)   @file / "add buffer files" 选择器
├── history_selector.lua    (78)   历史会话选择器
├── model_selector.lua     (162)   模型选择器
├── path.lua               (487)   每个 project 的持久化（聊天记录、metadata）路径计算
├── rag_service.lua        (448)   Docker / Nix 启动 RAG 后端容器 + retrieve API
├── repo_map.lua           (227)   调用 Rust avante_repo_map 生成项目符号表
├── selection_result.lua    (23)   选区数据结构
├── range.lua               (34)   行区间结构
├── tokenizers.lua          (73)   调用 Rust avante_tokenizers
├── html2md.lua             (29)   调用 Rust avante_html2md (fetch tool 用)
├── clipboard.lua           (73)   图片粘贴（依赖 img-clip.nvim）
├── health.lua             (104)   :checkhealth avante
├── highlights.lua         (223)   全部 hl group 定义
├── types.lua              (560)   ★★★ 全部 LuaCATS 类型注解（开发必读）
│
├── auth/
│   └── pkce.lua                   PKCE OAuth code_verifier / code_challenge（Claude Max 登录用）
│
├── extensions/                    可选第三方插件适配
│   ├── init.lua                   懒加载入口（__index 动态 require）
│   └── nvim_tree.lua              nvim-tree 集成：把树节点加入文件选择器
│
├── history/                       聊天历史的内存模型
│   ├── init.lua                   合并 entries↔messages、收集 tool_info
│   ├── helpers.lua                判定 tool_use / tool_result / 类型分发
│   ├── message.lua                avante.HistoryMessage 构造器
│   └── render.lua                 history → avante.ui.Line[]（侧边栏渲染源）
│
├── libs/                          通用底层库
│   ├── acp_client.lua      (993)  ★ Agent Client Protocol JSON-RPC 客户端（stdio 子进程）
│   ├── jsonparser.lua             零依赖手写 JSON parser（用于流式片段）
│   ├── xmlparser.lua              SAX 风格 XML parser
│   ├── ReAct_parser.lua           解析 <function_calls>…</function_calls> XML 协议（旧）
│   └── ReAct_parser2.lua          ReAct 协议 v2 解析器
│
├── llm_tools/                     ★ Agentic 工具实现（每个文件 = 一个工具）
│   ├── base.lua                   极简元表：__call(opts) → func(opts, on_log, on_complete)
│   ├── init.lua          (1385)   ★ 工具总线：注册表 M._tools、process_tool_use 调度、取消信号、内置 web_search/git_diff/git_commit/move_path/copy_path/delete_path/create_dir/read_global_file/write_global_file/python/rag_search/read_definitions
│   ├── helpers.lua                ★ 权限确认 UI、CANCEL_TOKEN、get_abs_path、auto_approve_tool_permissions
│   ├── ls.lua / glob.lua / grep.lua / view.lua          文件浏览
│   ├── bash.lua                   持久 shell 会话；带 banned_commands 黑名单
│   ├── str_replace.lua / replace_in_file.lua            旧式精确替换
│   ├── edit_file.lua              ★ Morph FastApply：把 "// ... existing code ..." 草稿交给小模型实施
│   ├── create.lua / write_to_file.lua / insert.lua / undo_edit.lua
│   ├── delete_tool_use_messages.lua  压缩历史时移除冗余工具调用
│   ├── dispatch_agent.lua         ★ 子 Agent：只能用 ls/grep/glob/view/attempt_completion
│   ├── attempt_completion.lua     标记任务结束（Cline 协议）
│   ├── get_diagnostics.lua        LSP 诊断 → 模型
│   ├── read_todos.lua / write_todos.lua  内置 TODO 列表（chat_history.todos）
│   └── think.lua                  纯思考占位工具
│
├── providers/                     ★ LLM Provider 适配层
│   ├── init.lua                   AvanteProviderFunctor 元表派生、__inherited_from 继承、环境变量解析（AVANTE_ 前缀作用域）
│   ├── claude.lua          (915)  Anthropic API + Claude Max OAuth（PKCE + refresh timer + lockfile）
│   ├── openai.lua          (894)  Chat Completions / Responses API、reasoning、tool_calls
│   ├── gemini.lua / vertex.lua / vertex_claude.lua
│   ├── azure.lua                  继承 openai
│   ├── bedrock.lua + bedrock/claude.lua    AWS Bedrock，按 model 动态 load_model_handler
│   ├── copilot.lua                GitHub Copilot token 兑换
│   ├── cohere.lua / ollama.lua / watsonx_code_assistant.lua
│   ├── aclaude.lua / aone.lua     字节/阿里内部 Provider 适配
│
├── templates/                     ★ Jinja 模板（filetype = jinja，扩展名 .avanterules）
│   ├── base.avanterules           其它模板的 extends 基类
│   ├── agentic.avanterules        Mode = "agentic" 系统 Prompt
│   ├── legacy.avanterules         Mode = "legacy" 系统 Prompt
│   ├── editing.avanterules        行内 Edit 系统 Prompt
│   ├── suggesting.avanterules     Auto-suggestion 系统 Prompt
│   ├── _gpt4-1-agentic.avanterules GPT-4.1 专属调优
│   └── _context / _diagnostics / _environments / _memory / _project / _task-guidelines / _tools-guidelines.avanterules
│       —— 下划线开头为 partial（被 {% include %}）
│
├── ui/                            UI 组件
│   ├── prompt_input.lua           浮窗输入（Ask / Edit 用）
│   ├── confirm.lua                工具调用授权弹窗
│   ├── acp_confirm_adapter.lua    把 ACP permissionOptions → 本地按钮
│   ├── line.lua                   带 hl_group 的渲染行抽象
│   ├── button_group_line.lua      行内按钮组（inline_buttons 模式）
│   ├── input/
│   │   ├── init.lua               统一入口（按 Config.input.provider 分派）
│   │   └── providers/{native,dressing,snacks}.lua
│   └── selector/
│       ├── init.lua               统一入口
│       └── providers/{native,fzf_lua,mini_pick,snacks,telescope}.lua
│
└── utils/                         工具集（lazy 懒加载子模块）
    ├── init.lua          (1892)   ★ 中枢：has/notify/visual_selection/get_commands/get_mentions/safe_keymap_set/scan_directory/parse_gitignore/uniform_path/shell_run_async/trim_think_content/is_edit_tool_use/get_chat_mentions …
    ├── path.lua                   纯字符串路径工具（basename/join/relative）
    ├── root.lua                   ★ project root 探测：LSP > VCS 标记 > package 文件
    ├── file.lua                   读文件、tail、stat
    ├── environment.lua            $VAR / cmd:xxx / shellenv 解析
    ├── lsp.lua                    diagnostic / definition / read_definitions
    ├── lru_cache.lua              纯 Lua LRU
    ├── tokens.lua                 调用 tokenizers 算 token
    ├── prompts.lua                组装 system / user prompt（载入模板）
    ├── promptLogger.lua           调试落盘 prompt
    ├── streaming_json_parser.lua  逐字符增量 JSON（处理流式 tool_use.input）
    ├── diff2search_replace.lua    将 unified diff → SEARCH/REPLACE 块
    ├── chat_id.lua                生成会话 UUID
    ├── logo.lua                   ASCII Logo
    ├── skill.lua                  Claude Skills 协议辅助
    └── test.lua                   测试辅助
```

---

## 3. 运行时数据流

### 3.1 启动序列（`require("avante").setup(opts)`）

`init.lua:495` `M.setup` 的顺序：

1. `Config.setup(opts)` — merge `_defaults` 与用户配置
2. `H.load_path()` — 注册 LazyLoad/VeryLazy autocmd，最终 `require("avante_lib").load()` 把 `build/?.{so|dylib|dll}` 追加进 `package.cpath`
3. 子系统 setup：`html2md / repo_map / path / highlights / diff / providers / clipboard`
4. `H.autocmds()` — 关键 autocmds：
   - `TabEnter` → `M._init(tab)` 为每个 tab 创建 Sidebar/Selection/Suggestion
   - `VimResized` → sidebar:resize
   - `QuitPre` → 最后一个非 sidebar window 关闭时关掉所有 sidebar window
   - `TabClosed` → 清理对应 tab 的状态
   - `VimLeavePre` → `cleanup_all_acp_clients()` + 取消 inflight curl
   - `ColorScheme/ColorSchemePre` → 重新 setup hl
   - `filetype.add` 把 `*.avanterules` 注册为 jinja
5. `H.keymaps()` — `<Plug>(Avante*)` + 若 `auto_set_keymaps` 则按 `Config.mappings` 实际绑定
6. `H.signs()` — 输入区 `>` 提示符 sign
7. RAG：若 `rag_service.enabled` → 启动容器 → 轮询 ready → 把 project root 注册为 resource
8. nvim-cmp：注册 `avante_commands / avante_mentions / avante_prompt_mentions / avante_shortcuts` 源

### 3.2 一次 Ask 的完整链路

```
user :AvanteAsk          (plugin/avante.lua)
   → api.ask({question})  (api.lua)
   → PromptInput / 直接 → sidebar:open() + AvanteInputSubmitted autocmd
   → sidebar:submit_input()
       └─ llm.stream({...})                     (llm.lua)
            ├─ Providers[Config.provider]:parse_curl_args(prompt_opts)
            ├─ plenary.curl.post(url, {stream = on_chunk})
            ├─ Provider:parse_response/parse_stream_data   逐 chunk → on_chunk
            │     ├─ 文本 → sidebar.update_content (HistoryMessage append)
            │     ├─ thinking → 灰色折叠块
            │     └─ tool_use → llm_tools.process_tool_use
            │           ├─ helpers.confirm (除非 auto_approve)
            │           ├─ tool.func(input, {on_log, on_complete, session_ctx, ...})
            │           └─ result → 作为 tool_result 写回 messages，再开 stream 一轮
            └─ on_stop({reason="complete|tool_use|error|max_tokens|cancelled"})
                 └─ history.save、token usage 更新、状态机切换
```

`llm.lua` 还实现：
- `M.summarize_memory` — 上下文窗口将满时用 `Config.memory_summary_provider` 浓缩历史
- `M.generate_todos` — 用户首条消息派生 TODO 列表（喂给 `write_todos` 工具）
- ACP 分支：若 `Config.acp_providers[provider]` 命中，走 `ACPClient` 而非 curl

### 3.3 Agentic Tool Use 调度（`llm_tools/init.lua`）

- 工具集合 = `M._tools`（静态注册）+ `Config.custom_tools`（可为函数）
- `M.get_tools(user_input, history_messages)` 按 `tool.enabled(opts)` 过滤，再剔除 `Config.disabled_tools`
- `M.process_tool_use(tools, tool_use, opts)`：
  - 启动 100ms 计时器轮询 `Helpers.is_cancelled`
  - 找到 `tool.func` 或 fallback `M[tool.name]`
  - 注入 `{ session_ctx, on_log, set_store, on_complete, streaming, tool_use_id }`
  - 同步返回 `(result, err)` 或异步（返回 nil, nil + 由 `on_complete` 回调）
- `Helpers.confirm` 是统一权限关口：
  - `behaviour.auto_approve_tool_permissions = true` → 全放
  - 数组 → 白名单
  - `session_ctx.always_yes` → 本会话放
  - `confirmation_ui_style = "inline_buttons"` → 行内按钮；否则浮窗

### 3.4 Provider 抽象（`providers/init.lua`）

`M = setmetatable({}, { __index = function(t, k) ... })` —— **第一次访问 `Providers.claude` 时**：

1. 读 `Config.providers[k]`
2. 若有 `__inherited_from` → 加载基 provider module + deep_extend
3. 否则 `require("avante.providers." .. k)`，与 user config deep_extend
4. 为没实现 `parse_api_key / is_env_set / setup` 的 provider 自动补默认实现
5. 默认 `tokenizer_id = "gpt-4o"`

环境变量解析顺序（`E.parse_envvar`）：
1. **AVANTE_-prefixed** scoped key（避免和别的工具串）
2. 原始 key
3. `cmd:foo bar` 形式 → 执行命令拿 stdout
4. `_shellenv` 注入

切换 provider：`api.switch_provider(name)` → `Providers.refresh(name)` → 重新 `E.setup` 并触发登录 UI。

### 3.5 ACP（Agent Client Protocol）

- `libs/acp_client.lua` 是一个完整 JSON-RPC 2.0 双向 stdio 客户端
- 配置在 `Config.acp_providers`（如 `claude-code`、`gemini-cli`）
- 生命周期：spawn 子进程 → `initialize` 握手 → `newSession` / `loadSession` → `prompt` → 流式收 `session/update`（含 `tool_call_update`、`plan`、`thought`、`text_chunk`）
- 工具权限：远端发 `session/request_permission` → 本地 `ACPConfirmAdapter.generate_buttons_for_acp_options` → UI 弹按钮 → 回 RPC
- 全局 registry：`init.lua:22 M.acp_clients`，`VimLeavePre` 时全部 `:stop()`

### 3.6 历史持久化（`path.lua` + `history/`）

- 路径：`stdpath('data')/avante/projects/<根目录路径编码>/history/{N}.json` + `metadata.json`
- `metadata.json` 记 `project_root` 和 `latest_filename`
- `avante.ChatHistory` 字段：`title / timestamp / messages / entries / todos / memory / filename / system_prompt / tokens_usage / acp_session_id`
- `entries`（旧版字段）与 `messages`（新版）由 `history.get_history_messages` 互转，向后兼容

### 3.7 模板引擎

- `Config.system_prompt`（字符串/函数）优先
- 否则 `Utils.prompts.get_*_system_prompt` 用 Rust 端 minijinja 渲染 `templates/*.avanterules`
- partial 文件 `_*.avanterules` 通过 `{% include %}` 注入：`_environments`（系统信息）、`_context`（选区/文件）、`_memory`、`_project`、`_diagnostics`、`_tools-guidelines`、`_task-guidelines`
- `override_prompt_dir` 让用户整目录覆盖

---

## 4. 关键类型（来自 `types.lua`）

强烈建议改任何 LLM/工具相关代码前 **先读** `lua/avante/types.lua`（560 行纯 `---@class`）。

最常用：

| 类型 | 用途 |
| --- | --- |
| `AvanteLLMMessage` | `{role, content}`，content 可为 string 或多模态 item 数组 |
| `AvanteLLMMessageContentItem` | text / image / tool_use / tool_result / thinking / redacted_thinking |
| `AvanteLLMTool` | 工具元数据：name / description / param / returns / enabled / on_render |
| `AvanteLLMToolFunc<T>` | 工具执行函数签名：`(input: T, opts) → (result, err)` |
| `AvanteLLMToolFuncOpts` | `{ session_ctx, on_complete, on_log, set_store, tool_use_id, streaming }` |
| `AvanteProviderFunctor` | Provider 接口：parse_messages / parse_response / parse_curl_args / setup / is_env_set / role_map / transform_tool / get_rate_limit_sleep_time / list_models |
| `AvanteHandlerOptions` | 流式回调集合：on_start / on_chunk / on_stop / on_messages_add / on_state_change / update_tokens_usage |
| `AvantePromptOptions` | `{ system_prompt, messages, image_paths?, tools? }` |
| `AvanteLLMStreamOptions` | stream() 的全部入参 |
| `avante.HistoryMessage` | 持久化的消息单元（含 uuid/turn_id/state/visible/is_dummy/…） |
| `avante.ChatHistory` | 一次会话的全量结构 |
| `avante.GenerateState` | `generating / tool calling / thinking / compacting / succeeded / failed / cancelled / initializing` |

---

## 5. 用户暴露面

### 5.1 Ex 命令（`plugin/avante.lua`）

`AvanteAsk` `AvanteChat` `AvanteChatNew` `AvanteEdit` `AvanteRefresh` `AvanteFocus` `AvanteBuild` `AvanteToggle` `AvanteStop` `AvanteSwitchProvider` `AvanteSwitchSelectorProvider` `AvanteSwitchInputProvider` `AvanteModels` `AvanteHistory` `AvanteClear` 等。

### 5.2 `<Plug>` 映射（`init.lua:89 H.keymaps`）

`<Plug>(AvanteAsk)` / `(AvanteAskNew)` / `(AvanteChat)` / `(AvanteEdit)` / `(AvanteRefresh)` / `(AvanteFocus)` / `(AvanteBuild)` / `(AvanteToggle)` / `(AvanteToggleDebug)` / `(AvanteToggleSelection)` / `(AvanteToggleSuggestion)` / `(AvanteSelectModel)` / `(AvanteConflict{Ours,Theirs,AllTheirs,Both,Cursor,NextConflict,PrevConflict})`

### 5.3 Lua API（`api.lua` 二级表）

```lua
require("avante.api").ask(opts)             -- AskOptions
require("avante.api").edit(req, l1, l2)
require("avante.api").refresh()
require("avante.api").focus()
require("avante.api").stop()
require("avante.api").build({source=true})
require("avante.api").select_model()
require("avante.api").select_history()
require("avante.api").switch_provider(name)
require("avante.api").switch_selector_provider(name)
require("avante.api").switch_input_provider(name)
require("avante.api").add_buffer_files()
require("avante.api").add_selected_file(path)
require("avante.api").remove_selected_file(path)
```

`api.lua` 末尾的 `__index` 会把未声明的访问回退到 `require("avante")` 上、且只暴露被 `H.api(...)` 标记的成员，从而控制公开面。

### 5.4 配置 hook 点

- `Config.custom_tools` — 增加工具（详见 `types.lua AvanteLLMToolPublic`）
- `Config.slash_commands` — `/foo` 自定义命令
- `Config.shortcuts` — `#foo` 快捷提示
- `Config.disabled_tools` — 黑名单
- `Config.behaviour.auto_approve_tool_permissions` — bool 或字符串数组
- `Config.system_prompt`, `Config.override_prompt_dir`
- `Config.rules.{project_dir, global_dir}` — 类似 `.cursorrules`
- `Config.web_search_engine.providers.<name>.format_response_body` — 用户自定义检索引擎

---

## 6. 写新代码时的约定

1. **类型注解必写**：所有公开函数加 `---@param` / `---@return`，类型放进 `types.lua` 或本模块顶部。
2. **路径处理走 `Utils.path` 与 `Utils.root`**，不要直接拼 `/`，Windows 会炸。
3. **路径权限**：访问磁盘前过 `Helpers.has_permission_to_access(abs_path)` + `Helpers.is_ignored(abs_path)`（gitignore 解析）。
4. **任何带副作用的 LLM tool 必须走 `Helpers.confirm`**（除非显式 dry-run）。把工具的 `name` 作为最后一个参数传入，以让 `auto_approve_tool_permissions` 数组能匹配。
5. **取消信号**：长时间操作要周期性检查 `Helpers.is_cancelled`，并在退出路径里关掉 timer / curl handle。
6. **新增 Provider**：
   - 若与已有协议兼容 → 用户侧 `__inherited_from = "openai"` 即可，不必新建 provider 文件
   - 否则在 `providers/foo.lua` 实现 `parse_curl_args / parse_response / parse_messages / role_map / api_key_name / setup / is_env_set / transform_tool`
   - **不要**在 provider 内部硬编码 endpoint，留作 `M.endpoint` 让用户覆盖
7. **新增 Tool**：
   - 推荐模板：`setmetatable({}, Base)` + `M.name / M.description / M.param / M.returns / M.func`
   - 在 `llm_tools/init.lua` 的 `M._tools` 数组里 `require` 它
   - 若工具会改文件，记得在 `Utils.is_edit_tool_use` 里被识别（驱动 sidebar 的 diff 展示）
   - 若需要自定义渲染 → 实现 `M.on_render: avante.LLMToolOnRender`
8. **流式工具**：参数里 `opts.streaming = true` 表示输入未必完整 —— 多数工具应立即 `return`（什么都不做），等非 streaming 终态到达再真正执行。`bash.lua:217` 是范例。
9. **不要新增顶层 require 循环**：`utils/init.lua` 使用 `__index` 懒加载子模块；新增子模块直接放进 `utils/`，不需要改 init。`providers/` `extensions/` 同模式。
10. **历史消息追加用 `HistoryMessage:new()`**，并通过 `on_messages_add` 回调；不要直接 `table.insert` 到 sidebar 的私有缓存。
11. **HL group** 在 `highlights.lua` 集中定义，渲染层只引用名字，不要硬编码颜色。
12. **commit 风格** 看 `git log`（项目用中文 `feat:` / `fix:` 前缀）。

---

## 7. 调试入口

| 场景 | 怎么做 |
| --- | --- |
| 查看实际发给模型的 prompt | `Config.debug = true` 后 `Utils.debug(...)` 会落 `:messages`；或开 `Utils.logger`（`utils/promptLogger.lua`）写文件 |
| 看 tool 调用日志 | sidebar 内每个工具卡片可展开看 `on_log` 输出 |
| ACP 协议级别 | `Utils.debug` 打开后 `acp_client.lua` 会打印每条 JSON-RPC |
| Provider HTTP 体 | 在 `parse_curl_args` 返回前 `Utils.debug(curl_output.body)` |
| 健康检查 | `:checkhealth avante` |
| 看 Lua 模块加载情况 | `:lua =package.loaded["avante.providers"]` |
| 取消 inflight 请求 | `:AvanteStop` 或映射 `<leader>aS`（默认） |

---

## 8. 与 Rust 后端的边界

`lua/` 只 `require` 三个 native 模块（在 `build/` 下）：

| Native 模块 | Lua 调用点 | 作用 |
| --- | --- | --- |
| `avante_repo_map` | `repo_map.lua`, `llm_tools/init.lua:read_file_toplevel_symbols` | tree-sitter 解析项目符号 |
| `avante_tokenizers` | `tokenizers.lua`, `utils/tokens.lua` | tiktoken / HF tokenizer |
| `avante_html2md` | `html2md.lua` → `fetch` 工具 | 抓网页转 markdown |

加载点都在 `avante_lib.lua:13 M.load()`；首次 require 失败时上层都做了优雅降级（warn 而不是 error）。

---

## 9. 常用检索备忘

- 改 system prompt → `templates/*.avanterules` + `utils/prompts.lua`
- 改 sidebar 布局 → `sidebar.lua` 中 `SIDEBAR_CONTAINERS` 常量与 `:render()`
- 改 auto-suggestion 触发条件 → `suggestion.lua` `setup_autocmds()` 与 `_timer`
- 改 diff 高亮/按键 → `diff.lua` + `Config.mappings.diff`
- 改持久化目录 → `Config.history.storage_path` + `path.lua`
- 改 RAG 行为 → `rag_service.lua` + `Config.rag_service`
- 改 OAuth → `providers/claude.lua` + `auth/pkce.lua`

---

## 10. 不要做的事

- ❌ 在工具实现里直接 `vim.fn.input(...)` —— 用 `Helpers.confirm` 或 `ui/input`
- ❌ 在 provider 里直接 `vim.notify` —— 用 `Utils.error/warn/info`（带 once 去重）
- ❌ 在 `llm.lua` 主流程里同步 sleep —— 全部异步回调
- ❌ 把秘钥写日志 —— `Utils.debug` 前先 `:gsub` 掉 Authorization
- ❌ 给 `bash` 工具加 `curl/wget/nc` 等网络命令到白名单 —— 是注入面，已被 `banned_commands` 拦截
- ❌ 假设 `M.current.sidebar` 总是非 nil —— 每个 tab 独立，先 `M.get()` 检查
