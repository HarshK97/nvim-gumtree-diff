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

function M.bottom_up_match(mappings, src_info, dst_info)
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

	for id, info in pairs(src_info) do
		if not is_mapped(id, true) and info.parent then
			local m = get_mapping(info.parent:id(), true)
			if m then
				local d_parent = dst_info[m.dst].node
				for child in d_parent:iter_children() do
					if not is_mapped(child:id(), false) and child:type() == info.type then
						table.insert(mappings, { src = id, dst = child:id() })
						break
					end
				end
			end
		end
	end

	return mappings
end

return M
