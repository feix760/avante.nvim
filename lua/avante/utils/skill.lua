local Utils = require("avante.utils")

local M = {}

function M.get_skills()
  local project_root = Utils.root.get()

  local skills = {}
  local skill_dirs = {
    vim.fn.expand("~/.agents/skills"),
    project_root .. "/.agents/skills",
  }
  local seen_skills = {}
  for _, skill_base_dir in ipairs(skill_dirs) do
    local dir = vim.loop.fs_scandir(skill_base_dir)
    if dir then
      while true do
        local name, type = vim.loop.fs_scandir_next(dir)
        if not name then break end
        if type == "directory" then
          local skill_file = skill_base_dir .. "/" .. name .. "/SKILL.md"
          if vim.loop.fs_stat(skill_file) and not seen_skills[name] then
            seen_skills[name] = true
            local content = table.concat(vim.fn.readfile(skill_file), "\n")
            local front_matter = content:match("^%-%-%-\n(.-)\n%-%-%-")
            if front_matter then
              local skill_name = front_matter:match("name:%s*([^\n]*)") or name
              local skill_desc = front_matter:match("description:%s*([^\n]*)") or ""
              skill_name = skill_name:gsub("%s+$", "")
              skill_desc = skill_desc:gsub("%s+$", "")
              table.insert(skills, "- name: " .. skill_name .. "\n  description: " .. skill_desc .. "\n  file_path: " .. skill_file)
            end
          end
        end
      end
    end
  end

  if #skills == 0 then
    table.insert(skills, "\nskill 列表为空")
  end

  return table.concat(skills, "\n")
end

return M
