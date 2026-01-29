vim.api.nvim_create_user_command("GumtreeDiff", function(opts)
	require("gumtree_diff").diff(opts.args)
end, {
	nargs = "+",
	complete = "file",
})
