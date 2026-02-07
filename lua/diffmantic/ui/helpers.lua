local M = {}

-- Leaf-level diffs for small updates; otherwise return empty.
function M.find_leaf_changes(src_node, dst_node, src_buf, dst_buf)
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

function M.node_in_field(parent, field_name, node)
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

function M.is_rename_identifier(node)
	if not node then
		return false
	end

	local node_type = node:type()
	if node_type ~= "identifier" and node_type ~= "type_identifier" and node_type ~= "field_identifier" then
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

	if parent_type == "assignment" and M.node_in_field(parent, "left", node) then
		return true
	end

	if parent_type == "assignment_statement" and M.node_in_field(parent, "variable", node) then
		return true
	end
	if parent_type == "variable_list" then
		return true
	end

	-- Language-specific name heuristics.
	local current = node
	while parent do
		local ptype = parent:type()
		if (ptype == "function_declaration" or ptype == "function_definition" or ptype == "class_definition" or ptype == "class_declaration")
			and M.node_in_field(parent, "name", current)
		then
			return true
		end
		if (ptype == "class_specifier" or ptype == "struct_specifier" or ptype == "enum_specifier" or ptype == "union_specifier")
			and (M.node_in_field(parent, "name", current) or M.node_in_field(parent, "tag", current))
		then
			return true
		end
		if ptype == "function_declarator" then
			return true
		end
		if ptype == "init_declarator" and M.node_in_field(parent, "declarator", current) then
			return true
		end
		if ptype == "field_declaration" and M.node_in_field(parent, "declarator", current) then
			return true
		end
		if ptype == "declarator" then
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

function M.is_value_node(node, text)
	local node_type = node and node:type() or ""
	if node_type:find("string") or node_type:find("number") or node_type:find("integer") or node_type:find("float") or node_type:find("boolean") then
		return true
	end
	if node_type == "char_literal" or node_type:find("char") and node_type:find("literal") then
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

function M.diff_fragment(old_text, new_text)
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

function M.set_inline_virt_text(buf, ns, row, col, text, hl)
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

function M.highlight_internal_diff(src_node, dst_node, src_buf, dst_buf, ns, opts)
	local src_text = vim.treesitter.get_node_text(src_node, src_buf)
	local dst_text = vim.treesitter.get_node_text(dst_node, dst_buf)
	if not src_text or not dst_text or src_text == "" or dst_text == "" then
		return false
	end

	local src_lines = vim.split(src_text, "\n", { plain = true })
	local dst_lines = vim.split(dst_text, "\n", { plain = true })

	local ok, hunks = pcall(vim.text.diff, src_text, dst_text, {
		result_type = "indices",
		linematch = 60,
	})

	local sr, _, er, _ = src_node:range()
	local tr, _, ter, _ = dst_node:range()
	local src_end = er - 1
	local dst_end = ter - 1
	local signs_src = opts and opts.signs_src or nil
	local signs_dst = opts and opts.signs_dst or nil
	local rename_map = opts and opts.rename_map or nil

	local function mark_fragment(buf, row, start_col, end_col, hl_group)
		if row < 0 or end_col <= start_col then
			return false
		end
		return pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, start_col, {
			end_row = row,
			end_col = end_col,
			hl_group = hl_group,
		})
	end

	local function mark_sign(buf, row, text, hl_group, sign_rows)
		if row < 0 then
			return false
		end
		if sign_rows and sign_rows[row] then
			return false
		end
		local ok = pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, 0, {
			sign_text = text,
			sign_hl_group = hl_group,
		})
		if ok and sign_rows then
			sign_rows[row] = true
		end
		return ok
	end

	local function tokenize_line(text)
		local tokens = {}
		local i = 1
		local len = #text
		while i <= len do
			local ch = text:sub(i, i)
			if ch:match("%s") then
				i = i + 1
			elseif ch:match("[%w_]") then
				local j = i + 1
				while j <= len and text:sub(j, j):match("[%w_]") do
					j = j + 1
				end
				table.insert(tokens, { text = text:sub(i, j - 1), start_col = i, end_col = j - 1 })
				i = j
			else
				local j = i + 1
				while j <= len and not text:sub(j, j):match("[%w_%s]") do
					j = j + 1
				end
				table.insert(tokens, { text = text:sub(i, j - 1), start_col = i, end_col = j - 1 })
				i = j
			end
		end
		return tokens
	end

	local function tokens_equal(a, b)
		if a.text == b.text then
			return true
		end
		if rename_map and rename_map[a.text] == b.text then
			return true
		end
		return false
	end

	local function lcs_matches(a, b)
		local n = #a
		local m = #b
		if n == 0 or m == 0 then
			return {}, {}
		end
		local dp = {}
		for i = 0, n do
			dp[i] = {}
			dp[i][0] = 0
		end
		for j = 1, m do
			dp[0][j] = 0
		end
		for i = 1, n do
			for j = 1, m do
				if tokens_equal(a[i], b[j]) then
					dp[i][j] = dp[i - 1][j - 1] + 1
				else
					local up = dp[i - 1][j]
					local left = dp[i][j - 1]
					dp[i][j] = (up >= left) and up or left
				end
			end
		end
		local match_a = {}
		local match_b = {}
		local i = n
		local j = m
		while i > 0 and j > 0 do
			if tokens_equal(a[i], b[j]) then
				match_a[i] = true
				match_b[j] = true
				i = i - 1
				j = j - 1
			else
				local up = dp[i - 1][j]
				local left = dp[i][j - 1]
				if up >= left then
					i = i - 1
				else
					j = j - 1
				end
			end
		end
		return match_a, match_b
	end

	local function mark_full_line(buf, row, hl_group)
		if row < 0 then
			return false
		end
		return pcall(vim.api.nvim_buf_set_extmark, buf, ns, row, 0, {
			end_row = row + 1,
			end_col = 0,
			hl_group = hl_group,
			hl_eol = true,
		})
	end

	local function highlight_line_pair(src_row, dst_row, s_line, d_line)
		if s_line and d_line and s_line ~= d_line then
			local tokens_src = tokenize_line(s_line)
			local tokens_dst = tokenize_line(d_line)
			if #tokens_src > 0 or #tokens_dst > 0 then
				local match_src, match_dst = lcs_matches(tokens_src, tokens_dst)
				local did_src = false
				local did_dst = false
				if src_row <= src_end then
					for i, tok in ipairs(tokens_src) do
						if not match_src[i] then
							did_src = mark_fragment(src_buf, src_row, tok.start_col - 1, tok.end_col, "DiffChangeText") or did_src
						end
					end
					if did_src then
						mark_sign(src_buf, src_row, "U", "DiffChangeText", signs_src)
					end
				end
				if dst_row <= dst_end then
					for i, tok in ipairs(tokens_dst) do
						if not match_dst[i] then
							did_dst = mark_fragment(dst_buf, dst_row, tok.start_col - 1, tok.end_col, "DiffChangeText") or did_dst
						end
					end
					if did_dst then
						mark_sign(dst_buf, dst_row, "U", "DiffChangeText", signs_dst)
					end
				end
				if did_src or did_dst then
					return true
				end
				return false
			end
			local fragment = M.diff_fragment(s_line, d_line)
			if fragment then
				local did = false
				if src_row <= src_end then
					did = mark_fragment(src_buf, src_row, fragment.old_start - 1, fragment.old_end, "DiffChangeText") or did
					mark_sign(src_buf, src_row, "U", "DiffChangeText", signs_src)
				end
				if dst_row <= dst_end then
					did = mark_fragment(dst_buf, dst_row, fragment.new_start - 1, fragment.new_end, "DiffChangeText") or did
					mark_sign(dst_buf, dst_row, "U", "DiffChangeText", signs_dst)
				end
				return did
			end
			local did = false
			if src_row <= src_end then
				did = mark_full_line(src_buf, src_row, "DiffChangeText") or did
				mark_sign(src_buf, src_row, "U", "DiffChangeText", signs_src)
			end
			if dst_row <= dst_end then
				did = mark_full_line(dst_buf, dst_row, "DiffChangeText") or did
				mark_sign(dst_buf, dst_row, "U", "DiffChangeText", signs_dst)
			end
			return did
		end
		if s_line and not d_line then
			if src_row <= src_end then
				mark_sign(src_buf, src_row, "-", "DiffDeleteText", signs_src)
				return mark_full_line(src_buf, src_row, "DiffDeleteText")
			end
		elseif d_line and not s_line then
			if dst_row <= dst_end then
				mark_sign(dst_buf, dst_row, "+", "DiffAddText", signs_dst)
				return mark_full_line(dst_buf, dst_row, "DiffAddText")
			end
		end
		return false
	end

	local did_highlight = false

	if ok and hunks and #hunks > 0 then
		for _, h in ipairs(hunks) do
			local start_a, count_a, start_b, count_b = h[1], h[2], h[3], h[4]
			local overlap = math.min(count_a, count_b)

			for i = 0, overlap - 1 do
				local src_row = sr + start_a - 1 + i
				local dst_row = tr + start_b - 1 + i
				local s_line = src_lines[start_a + i]
				local d_line = dst_lines[start_b + i]
				if highlight_line_pair(src_row, dst_row, s_line, d_line) then
					did_highlight = true
				end
			end

			if count_a > overlap then
				for i = overlap, count_a - 1 do
					local src_row = sr + start_a - 1 + i
					if src_row <= src_end then
						mark_sign(src_buf, src_row, "-", "DiffDeleteText", signs_src)
						did_highlight = mark_full_line(src_buf, src_row, "DiffDeleteText") or did_highlight
					end
				end
			end

			if count_b > overlap then
				for i = overlap, count_b - 1 do
					local dst_row = tr + start_b - 1 + i
					if dst_row <= dst_end then
						mark_sign(dst_buf, dst_row, "+", "DiffAddText", signs_dst)
						did_highlight = mark_full_line(dst_buf, dst_row, "DiffAddText") or did_highlight
					end
				end
			end
		end

		return did_highlight
	end

	local max_lines = math.max(#src_lines, #dst_lines)
	for i = 1, max_lines do
		local src_row = sr + i - 1
		local dst_row = tr + i - 1
		local s_line = src_lines[i]
		local d_line = dst_lines[i]
		if highlight_line_pair(src_row, dst_row, s_line, d_line) then
			did_highlight = true
		end
	end

	return did_highlight
end

return M
