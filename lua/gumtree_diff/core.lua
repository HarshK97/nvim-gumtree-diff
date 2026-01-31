local ts_utils = require("gumtree_diff.treesitter")

local M = {}

function M.top_down_match(src_root, dst_root, src_buf, dst_buf)
	local mappings = {}
	local src_info = ts_utils.preprocess_tree(src_root, src_buf)
	local dst_info = ts_utils.preprocess_tree(dst_root, dst_buf)

	local function get_nodes_by_height(info)
		local by_height = {}
		for _, data in pairs(info) do
			if not by_height[data.height] then
				by_height[data.height] = {}
			end
			table.insert(by_height[data.height], data)
		end
		return by_height
	end
	local src_by_height = get_nodes_by_height(src_info)
	local dst_by_height = get_nodes_by_height(dst_info)

	local max_h = 0
	for h in pairs(src_by_height) do
		if h > max_h then
			max_h = h
		end
	end
	for h in pairs(dst_by_height) do
		if h > max_h then
			max_h = h
		end
	end

	for h = max_h, 1, -1 do
		local s_nodes = src_by_height[h] or {}
		local d_nodes = dst_by_height[h] or {}

		for _, s in ipairs(s_nodes) do
			for _, d in ipairs(d_nodes) do
				if s.hash == d.hash then
					local s_mapped, d_mapped = false, false
					for _, m in ipairs(mappings) do
						if m.src == s.id then
							s_mapped = true
						end
						if m.dst == d.id then
							d_mapped = true
						end
					end
					if not s_mapped and not d_mapped then
						table.insert(mappings, { src = s.id, dst = d.id })
					end
				end
			end
		end
	end

	return mappings, src_info, dst_info
end

function M.bottom_up_match(mappings, src_info, dst_info, src_root, dst_root, src_buf, dst_buf)
	local function is_mapped(id, is_src)
		for _, m in ipairs(mappings) do
			if is_src and m.src == id then
				return true
			end
			if not is_src and m.dst == id then
				return true
			end
		end
		return false
	end
	local function get_mapping(id, is_src)
		for _, m in ipairs(mappings) do
			if is_src and m.src == id then
				return m
			end
			if not is_src and m.dst == id then
				return m
			end
		end
		return nil
	end

	local function get_declaration_name(node, bufnr)
		for child in node:iter_children() do
			if child:type() == "identifier" then
				return vim.treesitter.get_node_text(child, bufnr)
			end
		end

		-- Lua varibale_declaration
		if node:type() == "variable_declaration" then
			for child in node:iter_children() do
				if child:type() == "assignment_statement" then
					for subchild in child:iter_children() do
						if subchild:type() == "variable_list" then
							for id_node in subchild:iter_children() do
								if id_node:type() == "identifier" then
									return vim.treesitter.get_node_text(id_node, bufnr)
								end
							end
						end
					end
				end
			end
		end

		return nil
	end

	local identifier_types = {
		function_declaration = true,
		variable_declaration = true,
	}

	for id, info in pairs(src_info) do
		if not is_mapped(id, true) then
			local parent = info.parent
			local parent_mapped = false
			local dest_parent_id = nil

			if not parent then
				parent_mapped = true
			else
				local m = get_mapping(parent:id(), true)
				if m then
					parent_mapped = true
					dest_parent_id = m.dst
				end
			end

			if parent_mapped then
				local candidates = {}
				if dest_parent_id then
					local d_parent = dst_info[dest_parent_id].node
					for child in d_parent:iter_children() do
						if not is_mapped(child:id(), false) then
							table.insert(candidates, child)
						end
					end
				else
					if not is_mapped(dst_root:id(), false) then
						table.insert(candidates, dst_root)
					end
				end

				local src_name = nil
				if identifier_types[info.type] then
					src_name = get_declaration_name(info.node, src_buf)
				end

				for _, cand in ipairs(candidates) do
					local d_info = dst_info[cand:id()]
					if d_info.type == info.type and d_info.label == info.label then
						if src_name then
							local dst_name = get_declaration_name(cand, dst_buf)
							if src_name == dst_name then
								table.insert(mappings, { src = id, dst = cand:id() })
								break
							end
						else
							table.insert(mappings, { src = id, dst = cand:id() })
							break
						end
					end
				end
			end
		end
	end

	return mappings
end

return M
