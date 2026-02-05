local helpers = require("diffmantic.ui.helpers")

local M = {}

function M.render(src_buf, dst_buf, actions, ns)
	-- Suppress insert/delete inside moved/updated ranges.
	local src_suppress = {}
	local dst_suppress = {}

	local function add_range(ranges, node)
		if not node then
			return
		end
		local sr, _, er, _ = node:range()
		table.insert(ranges, { start_row = sr, end_row = er })
	end

	for _, action in ipairs(actions) do
		if action.type == "move" or action.type == "update" then
			add_range(src_suppress, action.node)
			add_range(dst_suppress, action.target)
		end
	end

	local function is_suppressed(ranges, node)
		if not node then
			return false
		end
		local sr, _, er, _ = node:range()
		for _, range in ipairs(ranges) do
			if sr >= range.start_row and er <= range.end_row then
				return true
			end
		end
		return false
	end

	for _, action in ipairs(actions) do
		local node = action.node
		local sr, sc, er, ec = node:range()

		if action.type == "move" then
			local target = action.target
			local tr, tc, ter, tec = target:range()
			local src_line = sr + 1
			local dst_line = tr + 1

			pcall(vim.api.nvim_buf_set_extmark, src_buf, ns, sr, sc, {
				end_row = er,
				end_col = ec,
				hl_group = "DiffText",
				virt_text = { { string.format(" ⤷ moved L%d → L%d", src_line, dst_line), "Comment" } },
				virt_text_pos = "eol",
				sign_text = "M",
				sign_hl_group = "DiffText",
			})
			pcall(vim.api.nvim_buf_set_extmark, dst_buf, ns, tr, tc, {
				end_row = ter,
				end_col = tec,
				hl_group = "DiffText",
				virt_text = { { string.format(" ⤶ from L%d", src_line), "Comment" } },
				virt_text_pos = "eol",
				sign_text = "M",
				sign_hl_group = "DiffText",
			})
		elseif action.type == "update" then
			local target = action.target
			local tr, tc, ter, tec = target:range()

			local leaf_changes = helpers.find_leaf_changes(node, target, src_buf, dst_buf)

			if #leaf_changes > 0 then
				local rename_signs = {}
				local rename_signs_src = {}
				local rename_was_lines = {}
				local update_signs = {}
				local has_other_changes = false

				for _, change in ipairs(leaf_changes) do
					local src_node = change.src_node
					local dst_node = change.dst_node
					local ctr, ctc, cter, ctec = dst_node:range()
					local csr, csc, cser, csec = src_node:range()

					if helpers.is_rename_identifier(src_node) or helpers.is_rename_identifier(dst_node) then
						-- Rename: highlight identifier, show ghost "was" line.
						if not rename_signs_src[csr] then
							rename_signs_src[csr] = true
							pcall(vim.api.nvim_buf_set_extmark, src_buf, ns, csr, csc, {
								end_row = cser,
								end_col = csec,
								hl_group = "DiffChange",
								sign_text = "R",
								sign_hl_group = "DiffChange",
							})
						else
							pcall(vim.api.nvim_buf_set_extmark, src_buf, ns, csr, csc, {
								end_row = cser,
								end_col = csec,
								hl_group = "DiffChange",
							})
						end

						if not rename_signs[ctr] then
							rename_signs[ctr] = true
							pcall(vim.api.nvim_buf_set_extmark, dst_buf, ns, ctr, ctc, {
								end_row = cter,
								end_col = ctec,
								hl_group = "DiffChange",
								sign_text = "R",
								sign_hl_group = "DiffChange",
							})
						else
							pcall(vim.api.nvim_buf_set_extmark, dst_buf, ns, ctr, ctc, {
								end_row = cter,
								end_col = ctec,
								hl_group = "DiffChange",
							})
						end

						if not rename_was_lines[ctr] then
							rename_was_lines[ctr] = true
							local line = vim.api.nvim_buf_get_lines(dst_buf, ctr, ctr + 1, false)[1] or ""
							local indent = line:match("^%s*") or ""
							pcall(vim.api.nvim_buf_set_extmark, dst_buf, ns, ctr, 0, {
								virt_lines = { { { indent .. "└─ was: " .. change.src_text, "Comment" } } },
							})
						end
					elseif helpers.is_value_node(src_node, change.src_text) or helpers.is_value_node(dst_node, change.dst_text) then
						-- Value change: micro-diff + inline "was".
						local fragment = helpers.diff_fragment(change.src_text, change.dst_text)
						if fragment then
							local rel_start = fragment.new_start - 1
							local rel_end = fragment.new_end
							if cter == ctr then
								pcall(vim.api.nvim_buf_set_extmark, dst_buf, ns, ctr, ctc + rel_start, {
									end_row = cter,
									end_col = ctc + rel_end,
									hl_group = "DiffChange",
								})
							end

							if not update_signs[ctr] then
								update_signs[ctr] = true
								pcall(vim.api.nvim_buf_set_extmark, dst_buf, ns, ctr, ctc + rel_end, {
									sign_text = "U",
									sign_hl_group = "DiffChange",
								})
							end

							local indent = string.rep(" ", math.max(0, ctc + rel_end))
							pcall(vim.api.nvim_buf_set_extmark, dst_buf, ns, ctr, 0, {
								virt_lines = { { { indent .. "└─ was: " .. fragment.old_fragment, "Comment" } } },
							})
						else
							pcall(vim.api.nvim_buf_set_extmark, dst_buf, ns, ctr, ctc, {
								end_row = cter,
								end_col = ctec,
								hl_group = "DiffChange",
								sign_text = "U",
								sign_hl_group = "DiffChange",
							})
							local indent = string.rep(" ", math.max(0, ctc))
							pcall(vim.api.nvim_buf_set_extmark, dst_buf, ns, ctr, 0, {
								virt_lines = { { { indent .. "└─ was: " .. change.src_text, "Comment" } } },
							})
						end
					else
						has_other_changes = true
					end
				end

				if has_other_changes then
					local did_line_diff = helpers.highlight_internal_diff(node, target, src_buf, dst_buf, ns)
					if not did_line_diff then
						pcall(vim.api.nvim_buf_set_extmark, src_buf, ns, sr, sc, {
							end_row = er,
							end_col = ec,
							hl_group = "DiffChange",
							sign_text = "U",
							sign_hl_group = "DiffChange",
						})
						pcall(vim.api.nvim_buf_set_extmark, dst_buf, ns, tr, tc, {
							end_row = ter,
							end_col = tec,
							hl_group = "DiffChange",
							sign_text = "U",
							sign_hl_group = "DiffChange",
						})
					end
				end
			else
				local did_line_diff = helpers.highlight_internal_diff(node, target, src_buf, dst_buf, ns)
				if not did_line_diff then
					pcall(vim.api.nvim_buf_set_extmark, src_buf, ns, sr, sc, {
						end_row = er,
						end_col = ec,
						hl_group = "DiffChange",
						sign_text = "U",
						sign_hl_group = "DiffChange",
					})
					pcall(vim.api.nvim_buf_set_extmark, dst_buf, ns, tr, tc, {
						end_row = ter,
						end_col = tec,
						hl_group = "DiffChange",
						sign_text = "U",
						sign_hl_group = "DiffChange",
					})
				end
			end
		elseif action.type == "delete" then
			if is_suppressed(src_suppress, node) then
				goto continue_action
			end
			pcall(vim.api.nvim_buf_set_extmark, src_buf, ns, sr, sc, {
				end_row = er,
				end_col = ec,
				hl_group = "DiffDelete",
				sign_text = "-",
				sign_hl_group = "DiffDelete",
			})
		elseif action.type == "insert" then
			if is_suppressed(dst_suppress, node) then
				goto continue_action
			end
			pcall(vim.api.nvim_buf_set_extmark, dst_buf, ns, sr, sc, {
				end_row = er,
				end_col = ec,
				hl_group = "DiffAdd",
				sign_text = "+",
				sign_hl_group = "DiffAdd",
			})
		end

		::continue_action::
	end
end

return M
