local M = {}

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

function M.setup(opts) end

return M
