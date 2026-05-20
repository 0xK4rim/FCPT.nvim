vim.api.nvim_create_user_command("FCPT", function(opts)
	require("FCPT").run(opts.args)
end, {
	nargs = "?",
	complete = "file",
})

vim.api.nvim_create_user_command("FCPTSetup", function()
	require("FCPT").setup()
end, {})

vim.keymap.set("n", "<leader>t", function()
	vim.cmd("FCPT")
end, { desc = "Run C++ test cases", silent = true })
