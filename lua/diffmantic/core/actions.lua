local M = {}

-- Generate edit actions from node mappings
-- Actions describe what changed: insert, delete, update, move
function M.generate_actions(src_root, dst_root, mappings, src_info, dst_info)
	local actions = {}

	-- Build O(1) lookup tables
	local src_to_dst = {}
	local dst_to_src = {}
	for _, m in ipairs(mappings) do
		src_to_dst[m.src] = m.dst
		dst_to_src[m.dst] = m.src
	end

	local significant_types = {
		function_declaration = true,
		variable_declaration = true,
		function_definition = true,
		class_specifier = true,
		struct_specifier = true,
		enum_specifier = true,
		union_specifier = true,
		namespace_definition = true,
		if_statement = true,
		return_statement = true,
		expression_statement = true,
		for_statement = true,
		while_statement = true,
		function_call = true,
		-- Python
		class_definition = true,
		import_statement = true,
		import_from_statement = true,
		decorator = true,
		-- C
		declaration = true,
		field_declaration = true,
		preproc_include = true,
		preproc_def = true,
		preproc_function_def = true,
	}

	local transparent_update_ancestors = {
		struct_specifier = true,
		class_specifier = true,
	}

	-- only these top-level constructs should be tracked for moves
	local movable_types = {
		function_declaration = true,
		function_definition = true,
		class_definition = true,
		class_specifier = true,
		struct_specifier = true,
	}

	-- Helper: check if node or any descendant has different content
	local function has_content_change(src_node, dst_node)
		local src_info_data = src_info[src_node:id()]
		local dst_info_data = dst_info[dst_node:id()]

		if src_info_data.hash ~= dst_info_data.hash then
			return true
		end

		return false
	end

	local nodes_with_changes = {}
	for _, m in ipairs(mappings) do
		local s, d = src_info[m.src], dst_info[m.dst]
		if has_content_change(s.node, d.node) then
			nodes_with_changes[m.src] = true
		end
	end

	-- Precompute ancestry flags for source nodes (unmapped significant ancestors)
	local src_has_unmapped_sig_ancestor = {}
	for id, info in pairs(src_info) do
		local current = info.parent
		while current do
			local p_id = current:id()
			local p_info = src_info[p_id]
			if p_info then
				if not src_to_dst[p_id] and significant_types[p_info.type] then
					src_has_unmapped_sig_ancestor[id] = true
					break
				end
				current = p_info.parent
			else
				break
			end
		end
	end

	-- Precompute ancestry flags for destination nodes (unmapped significant ancestors)
	local dst_has_unmapped_sig_ancestor = {}
	for id, info in pairs(dst_info) do
		local current = info.parent
		while current do
			local p_id = current:id()
			local p_info = dst_info[p_id]
			if p_info then
				if not dst_to_src[p_id] and significant_types[p_info.type] then
					dst_has_unmapped_sig_ancestor[id] = true
					break
				end
				current = p_info.parent
			else
				break
			end
		end
	end

	-- Precompute ancestry flags for updated significant ancestors
	local src_has_updated_sig_ancestor = {}
	for id, info in pairs(src_info) do
		local current = info.parent
		while current do
			local p_id = current:id()
			local p_info = src_info[p_id]
			if p_info then
				if nodes_with_changes[p_id]
					and significant_types[p_info.type]
					and not transparent_update_ancestors[p_info.type]
				then
					src_has_updated_sig_ancestor[id] = true
					break
				end
				current = p_info.parent
			else
				break
			end
		end
	end

	-- UPDATES: mapped nodes with different content, but only significant types without updated ancestors
	for _, m in ipairs(mappings) do
		local s, d = src_info[m.src], dst_info[m.dst]

		if nodes_with_changes[m.src] and significant_types[s.type] then
			if not src_has_updated_sig_ancestor[m.src] then
				table.insert(actions, { type = "update", node = s.node, target = d.node })
			end
		end
	end

	-- MOVES: check if parent changed or sibling order changed
	for _, m in ipairs(mappings) do
		local s, d = src_info[m.src], dst_info[m.dst]
		if not movable_types[s.type] then
			goto continue_move
		end
		if not s.parent or not d.parent then
			goto continue_move
		end

		local dst_of_src_parent = src_to_dst[s.parent:id()]
		local is_move = false

		local src_parent_is_root = (s.parent:id() == src_root:id())
		local dst_parent_is_root = (d.parent:id() == dst_root:id())

		if src_parent_is_root and dst_parent_is_root then
			is_move = false
		elseif dst_of_src_parent ~= d.parent:id() then
			is_move = true
		end

		if not is_move then
			local function mapped_movable_index(node, info_tbl, map_tbl)
				if not node or not node:parent() then
					return nil
				end
				local idx = 0
				for child in node:parent():iter_children() do
					local child_info = info_tbl[child:id()]
					if child_info and movable_types[child_info.type] and map_tbl[child:id()] then
						idx = idx + 1
						if child:id() == node:id() then
							return idx
						end
					end
				end
				return nil
			end

			local src_idx = mapped_movable_index(s.node, src_info, src_to_dst)
			local dst_idx = mapped_movable_index(d.node, dst_info, dst_to_src)
			if src_idx and dst_idx then
				if src_idx == dst_idx then
					goto continue_move
				else
					is_move = true
				end
			else
				local prev_src_sibling = nil
				for child in s.parent:iter_children() do
					if child:id() == s.node:id() then
						break
					end
					local child_info = src_info[child:id()]
					if src_to_dst[child:id()] and child_info and movable_types[child_info.type] then
						prev_src_sibling = child:id()
					end
				end

				local prev_dst_sibling = nil
				for child in d.parent:iter_children() do
					if child:id() == d.node:id() then
						break
					end
					local child_info = dst_info[child:id()]
					if dst_to_src[child:id()] and child_info and movable_types[child_info.type] then
						prev_dst_sibling = child:id()
					end
				end

				if prev_src_sibling then
					local expected_prev = src_to_dst[prev_src_sibling]
					if prev_dst_sibling ~= expected_prev then
						is_move = true
					end
				elseif prev_dst_sibling then
					is_move = true
				end
			end
		end

		if is_move then
			local src_line = s.node:range()
			local dst_line = d.node:range()
			local line_diff = math.abs(dst_line - src_line)
			if line_diff > 3 then
				table.insert(actions, { type = "move", node = s.node, target = d.node })
			end
		end

		::continue_move::
	end

	-- DELETES: unmapped source nodes
	for id, info in pairs(src_info) do
		if not src_to_dst[id] and significant_types[info.type] then
			if not src_has_unmapped_sig_ancestor[id] then
				table.insert(actions, { type = "delete", node = info.node })
			end
		end
	end

	-- INSERTS: unmapped destination nodes
	for id, info in pairs(dst_info) do
		if not dst_to_src[id] and significant_types[info.type] then
			if not dst_has_unmapped_sig_ancestor[id] then
				table.insert(actions, { type = "insert", node = info.node })
			end
		end
	end

	return actions
end

return M
