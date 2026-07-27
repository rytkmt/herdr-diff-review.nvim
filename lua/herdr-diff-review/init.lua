local M = {}

local config = {
  keymaps = {},
}

local state = {
  active = false,
  result_file = nil,
  original_buf = nil,
  modified_buf = nil,
}

function M.open_diff(original, modified, result_file, file_path)
  M._close_buffers()

  state.active = true
  state.result_file = result_file

  vim.cmd("edit " .. vim.fn.fnameescape(original))
  state.original_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(state.original_buf, file_path .. " [original]")
  vim.bo[state.original_buf].modifiable = false
  vim.bo[state.original_buf].buftype = "nofile"
  vim.bo[state.original_buf].bufhidden = "wipe"

  vim.cmd("vertical diffsplit " .. vim.fn.fnameescape(modified))
  state.modified_buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(state.modified_buf, file_path .. " [modified]")
  vim.bo[state.modified_buf].modifiable = false
  vim.bo[state.modified_buf].buftype = "nofile"
  vim.bo[state.modified_buf].bufhidden = "wipe"

  M._register_commands()

  if M._setup_done then
    M._set_keymaps()
  else
    vim.defer_fn(function()
      M._set_keymaps()
    end, 100)
  end
end

function M._write_result(decision)
  if not state.active then return end

  local f = io.open(state.result_file, "w")
  if f then
    f:write(decision)
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

  for _, buf in ipairs(bufs) do
    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end

  M._unregister_commands()
end

function M._register_commands()
  vim.api.nvim_create_user_command("HerdrDiffReviewAccept", function()
    M._write_result("accept")
  end, { desc = "Accept the proposed change" })

  vim.api.nvim_create_user_command("HerdrDiffReviewDeny", function()
    M._write_result("deny")
  end, { desc = "Deny the proposed change" })
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
