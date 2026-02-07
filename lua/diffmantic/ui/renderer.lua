local helpers = require("diffmantic.ui.helpers")

local M = {}

function M.render(src_buf, dst_buf, actions, ns)
	-- Suppress insert/delete inside moved/updated ranges.
	local src_suppress = {}
	local dst_suppress = {}
	local rename_map = {}

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

	for _, action in ipairs(actions) do
		if action.type == "update" then
			local leaf_changes = helpers.find_leaf_changes(action.node, action.target, src_buf, dst_buf)
			for _, change in ipairs(leaf_changes) do
				if helpers.is_rename_identifier(change.src_node) or helpers.is_rename_identifier(change.dst_node) then
					rename_map[change.src_text] = change.dst_text
				end
			end
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
				hl_group = "DiffMoveText",
				virt_text = { { string.format(" ⤷ moved L%d → L%d", src_line, dst_line), "Comment" } },
				virt_text_pos = "eol",
				sign_text = "M",
				sign_hl_group = "DiffMoveText",
			})
			pcall(vim.api.nvim_buf_set_extmark, dst_buf, ns, tr, tc, {
				end_row = ter,
				end_col = tec,
				hl_group = "DiffMoveText",
				virt_text = { { string.format(" ⤶ from L%d", src_line), "Comment" } },
				virt_text_pos = "eol",
				sign_text = "M",
				sign_hl_group = "DiffMoveText",
			})
		elseif action.type == "update" then
			local target = action.target
			local tr, tc, ter, tec = target:range()

			local leaf_changes = helpers.find_leaf_changes(node, target, src_buf, dst_buf)

			local signs_src = {}
			local signs_dst = {}
			if #leaf_changes > 0 then
				local rename_signs = {}
				local rename_signs_src = {}
				local rename_inline_src = {}
				local rename_inline_dst = {}
				local update_signs_dst = {}
				local update_signs_src = {}
				local rename_pairs = {}

				for src_text, dst_text in pairs(rename_map) do
					rename_pairs[src_text] = dst_text
				end

				for _, change in ipairs(leaf_changes) do
					local src_node = change.src_node
					local dst_node = change.dst_node
					if helpers.is_rename_identifier(src_node) or helpers.is_rename_identifier(dst_node) then
						rename_pairs[change.src_text] = change.dst_text
					end
				end

				for _, change in ipairs(leaf_changes) do
					local src_node = change.src_node
					local dst_node = change.dst_node
					local ctr, ctc, cter, ctec = dst_node:range()
					local csr, csc, cser, csec = src_node:range()

					local is_rename_ref = false
					if not (helpers.is_rename_identifier(src_node) or helpers.is_rename_identifier(dst_node)) then
						local src_type = src_node:type()
						local dst_type = dst_node:type()
						if
							(
								src_type == "identifier"
								or src_type == "field_identifier"
								or src_type == "type_identifier"
							)
							and (dst_type == "identifier" or dst_type == "field_identifier" or dst_type == "type_identifier")
							and (
								rename_pairs[change.src_text] == change.dst_text
								or rename_map[change.src_text] == change.dst_text
							)
						then
							is_rename_ref = true
						end
					end

					if is_rename_ref then
						-- Identifier usage changed only due to rename; ignore to avoid noise.
						goto continue_leaf
					end

					if helpers.is_rename_identifier(src_node) or helpers.is_rename_identifier(dst_node) then
						-- Rename: highlight identifier with inline "was"/"->".
						if not rename_signs_src[csr] then
							rename_signs_src[csr] = true
							signs_src[csr] = true
							pcall(vim.api.nvim_buf_set_extmark, src_buf, ns, csr, csc, {
								end_row = cser,
								end_col = csec,
								hl_group = "DiffRenameText",
								sign_text = "R",
								sign_hl_group = "DiffRenameText",
							})
						else
							pcall(vim.api.nvim_buf_set_extmark, src_buf, ns, csr, csc, {
								end_row = cser,
								end_col = csec,
								hl_group = "DiffChangeText",
							})
						end

						if not rename_signs[ctr] then
							rename_signs[ctr] = true
							signs_dst[ctr] = true
							pcall(vim.api.nvim_buf_set_extmark, dst_buf, ns, ctr, ctc, {
								end_row = cter,
								end_col = ctec,
								hl_group = "DiffRenameText",
								sign_text = "R",
								sign_hl_group = "DiffRenameText",
							})
						else
							signs_dst[ctr] = true
							pcall(vim.api.nvim_buf_set_extmark, dst_buf, ns, ctr, ctc, {
								end_row = cter,
								end_col = ctec,
								hl_group = "DiffChangeText",
							})
						end
						local src_key = tostring(src_node:id())
						if not rename_inline_src[src_key] then
							rename_inline_src[src_key] = true
							helpers.set_inline_virt_text(src_buf, ns, csr, csec, " -> " .. change.dst_text, "Comment")
						end
						local dst_key = tostring(dst_node:id())
						if not rename_inline_dst[dst_key] then
							rename_inline_dst[dst_key] = true
							helpers.set_inline_virt_text(
								dst_buf,
								ns,
								ctr,
								ctec,
								string.format(" (was %s)", change.src_text),
								"Comment"
							)
						end
					elseif
						helpers.is_value_node(src_node, change.src_text)
						or helpers.is_value_node(dst_node, change.dst_text)
					then
						-- Value change: micro-diff only (no virtual text).
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
							if cser == csr then
								pcall(vim.api.nvim_buf_set_extmark, src_buf, ns, csr, csc + fragment.old_start - 1, {
									end_row = cser,
									end_col = csc + fragment.old_end,
									hl_group = "DiffChange",
								})
							end

							if not update_signs_dst[ctr] then
								update_signs_dst[ctr] = true
								signs_dst[ctr] = true
								pcall(vim.api.nvim_buf_set_extmark, dst_buf, ns, ctr, ctc + rel_end, {
									sign_text = "U",
									sign_hl_group = "DiffChangeText",
								})
							end
							if not update_signs_src[csr] then
								update_signs_src[csr] = true
								signs_src[csr] = true
								pcall(vim.api.nvim_buf_set_extmark, src_buf, ns, csr, csc + fragment.old_end, {
									sign_text = "U",
									sign_hl_group = "DiffChangeText",
								})
							end
						else
							pcall(vim.api.nvim_buf_set_extmark, dst_buf, ns, ctr, ctc, {
								end_row = cter,
								end_col = ctec,
								hl_group = "DiffChange",
								sign_text = "U",
								sign_hl_group = "DiffChangeText",
							})
							if cser == csr then
								if not update_signs_src[csr] then
									update_signs_src[csr] = true
									signs_src[csr] = true
									pcall(vim.api.nvim_buf_set_extmark, src_buf, ns, csr, csc, {
										end_row = cser,
										end_col = csec,
										hl_group = "DiffChange",
										sign_text = "U",
										sign_hl_group = "DiffChangeText",
									})
								else
									pcall(vim.api.nvim_buf_set_extmark, src_buf, ns, csr, csc, {
										end_row = cser,
										end_col = csec,
										hl_group = "DiffChange",
									})
								end
							end
						end
					else
						if cser >= csr then
							pcall(vim.api.nvim_buf_set_extmark, src_buf, ns, csr, csc, {
								end_row = cser,
								end_col = csec,
								hl_group = "DiffChangeText",
							})
						end
						if cter >= ctr then
							pcall(vim.api.nvim_buf_set_extmark, dst_buf, ns, ctr, ctc, {
								end_row = cter,
								end_col = ctec,
								hl_group = "DiffChangeText",
							})
						end
						if not update_signs_src[csr] then
							update_signs_src[csr] = true
							signs_src[csr] = true
							pcall(vim.api.nvim_buf_set_extmark, src_buf, ns, csr, csc, {
								sign_text = "U",
								sign_hl_group = "DiffChangeText",
							})
						end
						if not update_signs_dst[ctr] then
							update_signs_dst[ctr] = true
							signs_dst[ctr] = true
							pcall(vim.api.nvim_buf_set_extmark, dst_buf, ns, ctr, ctc, {
								sign_text = "U",
								sign_hl_group = "DiffChangeText",
							})
						end
					end

					::continue_leaf::
				end
			else
				helpers.highlight_internal_diff(node, target, src_buf, dst_buf, ns, {
					signs_src = signs_src,
					signs_dst = signs_dst,
					rename_map = rename_map,
				})
			end
		elseif action.type == "delete" then
			if is_suppressed(src_suppress, node) and node:type() ~= "field_declaration" then
				goto continue_action
			end
			pcall(vim.api.nvim_buf_set_extmark, src_buf, ns, sr, sc, {
				end_row = er,
				end_col = ec,
				hl_group = "DiffDeleteText",
				sign_text = "-",
				sign_hl_group = "DiffDeleteText",
			})
		elseif action.type == "insert" then
			if is_suppressed(dst_suppress, node) and node:type() ~= "field_declaration" then
				goto continue_action
			end
			pcall(vim.api.nvim_buf_set_extmark, dst_buf, ns, sr, sc, {
				end_row = er,
				end_col = ec,
				hl_group = "DiffAddText",
				sign_text = "+",
				sign_hl_group = "DiffAddText",
			})
		end

		::continue_action::
	end
end

return M
