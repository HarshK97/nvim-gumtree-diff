local M = {}
local core = require("gumtree_diff.core")

function M.setup(opts) end

function M.diff(args)
	local parts = vim.split(args, " ", { trimempty = true })
	local file1, file2 = parts[1], parts[2]

	vim.cmd("tabnew")
	vim.cmd("edit " .. file1)
	local buf1 = vim.api.nvim_get_current_buf()
	vim.cmd("vsplit " .. file2)
	local buf2 = vim.api.nvim_get_current_buf()

	local lang = vim.treesitter.language.get_lang(vim.bo[buf1].filetype)
	local parser1 = vim.treesitter.get_parser(buf1, lang)
	local parser2 = vim.treesitter.get_parser(buf2, lang)
	local root1 = parser1:parse()[1]:root()
	local root2 = parser2:parse()[1]:root()

	local mappings, src_info, dst_info = core.top_down_match(root1, root2, buf1, buf2)
	print("Top-down mappings: " .. #mappings)

	mappings = core.bottom_up_match(mappings, src_info, dst_info)
	print("Total mappings after Bottom-up: " .. #mappings)
end

return M
