local M = {}

local config = {
  keymaps = {},
}

local state = {
  active = false,
  result_file = nil,
  modified_path = nil,
  original_buf = nil,
  modified_buf = nil,
}

function M.open_diff(original, modified, result_file, file_path)
  M._close_buffers()

  state.active = true
  state.result_file = result_file
  state.modified_path = modified

  local ft = vim.filetype.match({ filename = file_path }) or ""

  vim.cmd("edit " .. vim.fn.fnameescape(original))
  state.original_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(state.original_buf, file_path .. " [original]")
  vim.bo[state.original_buf].modifiable = false
  vim.bo[state.original_buf].buftype = "nofile"
  vim.bo[state.original_buf].bufhidden = "wipe"
  vim.bo[state.original_buf].filetype = ft
  vim.cmd("diffthis")

  vim.cmd("vertical split")
  state.modified_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, state.modified_buf)
  vim.bo[state.modified_buf].buftype = "nofile"
  vim.bo[state.modified_buf].bufhidden = "wipe"
  local modified_lines = vim.fn.readfile(modified)
  vim.api.nvim_buf_set_lines(state.modified_buf, 0, -1, false, modified_lines)
  vim.api.nvim_buf_set_name(state.modified_buf, file_path .. " [modified]")
  vim.bo[state.modified_buf].filetype = ft
  vim.cmd("diffthis")

  M._register_commands()

  if M._setup_done then
    M._set_keymaps()
  else
    vim.defer_fn(function()
      M._set_keymaps()
    end, 100)
  end
end

function M._write_result(decision, message)
  if not state.active then return end

  if decision == "accept" and state.modified_buf and vim.api.nvim_buf_is_valid(state.modified_buf) then
    local buf_lines = vim.api.nvim_buf_get_lines(state.modified_buf, 0, -1, false)
    local orig_lines = vim.fn.readfile(state.modified_path)

    local changed = #buf_lines ~= #orig_lines
    if not changed then
      for i, line in ipairs(buf_lines) do
        if line ~= orig_lines[i] then
          changed = true
          break
        end
      end
    end

    if changed then
      local wf = io.open(state.modified_path, "w")
      if wf then
        wf:write(table.concat(buf_lines, "\n") .. "\n")
        wf:close()
      end
      decision = "accept_edited"
    end
  end

  local f = io.open(state.result_file, "w")
  if f then
    f:write(decision)
    if message and message ~= "" then
      f:write("\n" .. message)
    end
    f:close()
  end

  M._close_buffers()
end

function M._close_buffers()
  local bufs = { state.original_buf, state.modified_buf }
  state.original_buf = nil
  state.modified_buf = nil
  state.active = false
  state.result_file = nil
  state.modified_path = nil

  for _, buf in ipairs(bufs) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end

  M._unregister_commands()
end

function M._register_commands()
  vim.api.nvim_create_user_command("HerdrDiffReviewAccept", function(opts)
    M._write_result("accept", opts.args)
  end, { nargs = "?", desc = "Accept the proposed change" })

  vim.api.nvim_create_user_command("HerdrDiffReviewDeny", function(opts)
    M._write_result("deny", opts.args)
  end, { nargs = "?", desc = "Deny the proposed change" })
end

function M._unregister_commands()
  pcall(vim.api.nvim_del_user_command, "HerdrDiffReviewAccept")
  pcall(vim.api.nvim_del_user_command, "HerdrDiffReviewDeny")
end

function M._set_keymaps()
  local bufs = { state.original_buf, state.modified_buf }
  for _, buf in ipairs(bufs) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      if config.keymaps.accept then
        vim.keymap.set("n", config.keymaps.accept, "<cmd>HerdrDiffReviewAccept<cr>", { buffer = buf })
      end
      if config.keymaps.deny then
        vim.keymap.set("n", config.keymaps.deny, "<cmd>HerdrDiffReviewDeny<cr>", { buffer = buf })
      end
      if config.keymaps.accept_with_message then
        vim.keymap.set("n", config.keymaps.accept_with_message, function()
          local msg = vim.fn.input("Accept message: ")
          if msg ~= "" then
            vim.cmd("HerdrDiffReviewAccept " .. msg)
          else
            vim.cmd("HerdrDiffReviewAccept")
          end
        end, { buffer = buf })
      end
      if config.keymaps.deny_with_message then
        vim.keymap.set("n", config.keymaps.deny_with_message, function()
          local msg = vim.fn.input("Deny reason: ")
          if msg ~= "" then
            vim.cmd("HerdrDiffReviewDeny " .. msg)
          else
            vim.cmd("HerdrDiffReviewDeny")
          end
        end, { buffer = buf })
      end
    end
  end
end

function M.setup(opts)
  config = vim.tbl_deep_extend("force", config, opts or {})
  M._setup_done = true

  if state.active then
    M._set_keymaps()
  end
end

return M
