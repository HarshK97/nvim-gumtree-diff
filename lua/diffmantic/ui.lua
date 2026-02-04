local M = {}

local ns = vim.api.nvim_create_namespace("GumtreeDiff")

function M.clear_highlights(bufnr)
	if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
		vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
	end
end

-- Leaf-level diffs for small updates; otherwise return empty.
local function find_leaf_changes(src_node, dst_node, src_buf, dst_buf)
	local changes = {}

	local function get_all_leaves(node, bufnr)
		local leaves = {}
		local function traverse(n)
			if n:child_count() == 0 then
				table.insert(leaves, {
					node = n,
					text = vim.treesitter.get_node_text(n, bufnr),
					type = n:type(),
				})
			else
				for child in n:iter_children() do
					traverse(child)
				end
			end
		end
		traverse(node)
		return leaves
	end

	local src_leaves = get_all_leaves(src_node, src_buf)
	local dst_leaves = get_all_leaves(dst_node, dst_buf)

	if #src_leaves ~= #dst_leaves then
		return {}
	end

	if math.abs(#src_leaves - #dst_leaves) > 2 then
		return {}
	end

	local min_len = math.min(#src_leaves, #dst_leaves)
	local max_len = math.max(#src_leaves, #dst_leaves)
	local same_count = 0

	for i = 1, min_len do
		local sl, dl = src_leaves[i], dst_leaves[i]
		if sl.type == dl.type and sl.text == dl.text then
			same_count = same_count + 1
		elseif sl.type == dl.type and sl.text ~= dl.text then
			table.insert(changes, {
				src_node = sl.node,
				dst_node = dl.node,
				src_text = sl.text,
				dst_text = dl.text,
			})
		end
	end

	local similarity = same_count / max_len

	if similarity < 0.5 then
		return {}
	end

	if #changes > 5 then
		return {}
	end

	return changes
end

local function node_in_field(parent, field_name, node)
	local nodes = parent:field(field_name)
	if not nodes then
		return false
	end
	for _, field_node in ipairs(nodes) do
		if field_node:equal(node) or field_node:child_with_descendant(node) then
			return true
		end
	end
	return false
end

local function is_rename_identifier(node)
	if not node then
		return false
	end

	local node_type = node:type()
	if node_type ~= "identifier" then
		return false
	end

	local parent = node:parent()
	if not parent then
		return false
	end

	local parent_type = parent:type()
	if parent_type == "parameters" or parent_type == "parameter_list" or parent_type == "formal_parameters" then
		return true
	end

	if parent_type == "assignment" and node_in_field(parent, "left", node) then
		return true
	end

	if parent_type == "assignment_statement" and node_in_field(parent, "variable", node) then
		return true
	end

	-- Language-specific name heuristics.
	local current = node
	while parent do
		local ptype = parent:type()
		if (ptype == "function_declaration" or ptype == "function_definition" or ptype == "class_definition" or ptype == "class_declaration")
			and node_in_field(parent, "name", current)
		then
			return true
		end
		if ptype == "field" then
			return true
		end
		current = parent
		parent = parent:parent()
	end

	return false
end

local function is_value_node(node, text)
	local node_type = node and node:type() or ""
	if node_type:find("string") or node_type:find("number") or node_type:find("integer") or node_type:find("float") or node_type:find("boolean") then
		return true
	end
	if text then
		if text:match("^%s*['\"].*['\"]%s*$") then
			return true
		end
		if text:match("^%s*[%d%.]+%s*$") then
			return true
		end
		if text == "true" or text == "false" or text == "nil" then
			return true
		end
	end
	return false
end

local function expand_word_fragment(text, start_idx, end_idx)
	local s = start_idx
	local e = end_idx
	while s > 1 and text:sub(s - 1, s - 1):match("[%w_]") do
		s = s - 1
	end
	while e <= #text and text:sub(e, e):match("[%w_]") do
		e = e + 1
	end
	return s, e - 1
end

local function diff_fragment(old_text, new_text)
	if old_text == new_text then
		return nil
	end

	local max_prefix = math.min(#old_text, #new_text)
	local prefix = 0
	while prefix < max_prefix and old_text:sub(prefix + 1, prefix + 1) == new_text:sub(prefix + 1, prefix + 1) do
		prefix = prefix + 1
	end

	local max_suffix = math.min(#old_text - prefix, #new_text - prefix)
	local suffix = 0
	while suffix < max_suffix do
		local o = old_text:sub(#old_text - suffix, #old_text - suffix)
		local n = new_text:sub(#new_text - suffix, #new_text - suffix)
		if o ~= n then
			break
		end
		suffix = suffix + 1
	end

	local old_start = prefix + 1
	local old_end = #old_text - suffix
	local new_start = prefix + 1
	local new_end = #new_text - suffix

	if old_start > old_end or new_start > new_end then
		return nil
	end

	old_start, old_end = expand_word_fragment(old_text, old_start, old_end)
	new_start, new_end = expand_word_fragment(new_text, new_start, new_end)

	return {
		old_start = old_start,
		old_end = old_end,
		new_start = new_start,
		new_end = new_end,
		old_fragment = old_text:sub(old_start, old_end),
		new_fragment = new_text:sub(new_start, new_end),
	}
end

local function set_inline_virt_text(buf, ns, row, col, text, hl)
	local opts = {
		virt_text = { { text, hl } },
		virt_text_pos = "inline",
	}
	local ok = pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, col, opts)
	if ok then
		return
	end
	opts.virt_text_pos = "eol"
	pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, col, opts)
end

local function highlight_internal_diff(src_node, dst_node, src_buf, dst_buf, ns)
	local src_text = vim.treesitter.get_node_text(src_node, src_buf)
	local dst_text = vim.treesitter.get_node_text(dst_node, dst_buf)
	if not src_text or not dst_text or src_text == "" or dst_text == "" then
		return false
	end

	local src_lines = vim.split(src_text, "\n", { plain = true })
	local dst_lines = vim.split(dst_text, "\n", { plain = true })

	local function is_comment_only(line)
		local trimmed = (line or ""):match("^%s*(.-)%s*$")
		if trimmed == "" then
			return true
		end
		if trimmed:match("^%-%-") or trimmed:match("^#") or trimmed:match("^//") then
			return true
		end
		return false
	end

	local ok, hunks = pcall(vim.text.diff, src_text, dst_text, {
		result_type = "indices",
		linematch = 60,
	})
	if not ok or not hunks or #hunks == 0 then
		return false
	end

	local sr, _, er, _ = src_node:range()
	local tr, _, ter, _ = dst_node:range()
	local src_end = er - 1
	local dst_end = ter - 1

	for _, h in ipairs(hunks) do
		local start_a, count_a, start_b, count_b = h[1], h[2], h[3], h[4]

		if count_a > 0 then
			local row_start = sr + start_a - 1
			local row_end = math.min(row_start + count_a - 1, src_end)
			if row_end >= row_start then
				pcall(vim.api.nvim_buf_set_extmark, src_buf, ns, row_start, 0, {
					end_row = row_end + 1,
					end_col = 0,
					hl_group = (count_b > 0) and "DiffChange" or "DiffDelete",
					hl_eol = true,
				})
			end
		end

		if count_b > 0 then
			local row_start = tr + start_b - 1
			local row_end = math.min(row_start + count_b - 1, dst_end)
			if row_end >= row_start then
				pcall(vim.api.nvim_buf_set_extmark, dst_buf, ns, row_start, 0, {
					end_row = row_end + 1,
					end_col = 0,
					hl_group = (count_a > 0) and "DiffChange" or "DiffAdd",
					hl_eol = true,
				})
			end
		end

		-- Preserve delete/add visibility when comment-only lines differ.
		if count_a > 0 and count_b > 0 and count_a == count_b then
			for i = 0, count_a - 1 do
				local s_line = src_lines[start_a + i]
				local d_line = dst_lines[start_b + i]
				if s_line and d_line then
					if not is_comment_only(s_line) and is_comment_only(d_line) then
						local row_start = sr + start_a - 1 + i
						if row_start <= src_end then
							pcall(vim.api.nvim_buf_set_extmark, src_buf, ns, row_start, 0, {
								end_row = row_start + 1,
								end_col = 0,
								hl_group = "DiffDelete",
								hl_eol = true,
								priority = 5000,
							})
						end
					elseif is_comment_only(s_line) and not is_comment_only(d_line) then
						local row_start = tr + start_b - 1 + i
						if row_start <= dst_end then
							pcall(vim.api.nvim_buf_set_extmark, dst_buf, ns, row_start, 0, {
								end_row = row_start + 1,
								end_col = 0,
								hl_group = "DiffAdd",
								hl_eol = true,
								priority = 5000,
							})
						end
					end
				end
			end
		end

		if count_a > count_b then
			local extra = count_a - count_b
			local row_start = sr + start_a - 1 + (count_a - extra)
			local row_end = math.min(row_start + extra - 1, src_end)
			if row_end >= row_start then
				pcall(vim.api.nvim_buf_set_extmark, src_buf, ns, row_start, 0, {
					end_row = row_end + 1,
					end_col = 0,
					hl_group = "DiffDelete",
					hl_eol = true,
					priority = 5000,
				})
			end
		elseif count_b > count_a then
			local extra = count_b - count_a
			local row_start = tr + start_b - 1 + (count_b - extra)
			local row_end = math.min(row_start + extra - 1, dst_end)
			if row_end >= row_start then
				pcall(vim.api.nvim_buf_set_extmark, dst_buf, ns, row_start, 0, {
					end_row = row_end + 1,
					end_col = 0,
					hl_group = "DiffAdd",
					hl_eol = true,
					priority = 5000,
				})
			end
		end
	end

	return true
end

function M.apply_highlights(src_buf, dst_buf, actions)
	M.clear_highlights(src_buf)
	M.clear_highlights(dst_buf)

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

			local leaf_changes = find_leaf_changes(node, target, src_buf, dst_buf)

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

					if is_rename_identifier(src_node) or is_rename_identifier(dst_node) then
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
					elseif is_value_node(src_node, change.src_text) or is_value_node(dst_node, change.dst_text) then
						-- Value change: micro-diff + inline "was".
						local fragment = diff_fragment(change.src_text, change.dst_text)
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
					local did_line_diff = highlight_internal_diff(node, target, src_buf, dst_buf, ns)
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
				local did_line_diff = highlight_internal_diff(node, target, src_buf, dst_buf, ns)
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
