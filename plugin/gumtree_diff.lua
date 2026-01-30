if vim.g.loaded_gumtree_diff then
	return
end

vim.g.loaded_gumtree_diff = 1

vim.api.nvim_create_user_command("GumtreeDiff", function(opts)
	require("gumtree_diff").diff(opts.args)
end, {
	nargs = "+",
	complete = "file",
	desc = "Semantic diff using GumTree algorithm",
})
