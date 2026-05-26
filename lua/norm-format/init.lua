local M = {}

function M.setup(opts)
    opts = opts or {}
    local group = vim.api.nvim_create_augroup("NormFormat", { clear = true })
    vim.api.nvim_create_autocmd("BufWritePre", {
        group = group,
        pattern = { "*.c", "*.h" },
        callback = function()
            M.format()
        end,
    })
end

local function split_initializations()
    local bufnr = vim.api.nvim_get_current_buf()
    local query_string = [[
        (declaration
            type: (_) @type
            declarator: (init_declarator
                declarator: (_) @name
                value: (_) @value)) @decl
    ]]
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, "c")
    if not ok or not parser then return end
    local tree = parser:parse()[1]
    local root = tree:root()
    local query = vim.treesitter.query.parse("c", query_string)
    local changes = {}
    for _, match, _ in query:iter_matches(root, bufnr, 0, -1) do
        local decl_node, type_node, name_node, value_node = nil, nil, nil, nil
        for id, nodes in pairs(match) do
            local name = query.captures[id]
            if name == "decl" then decl_node = nodes[1]
            elseif name == "type" then type_node = nodes[1]
            elseif name == "name" then name_node = nodes[1]
            elseif name == "value" then value_node = nodes[1] end
        end
        if decl_node and type_node and name_node and value_node then
            local parent = decl_node:parent()
            local is_inside_func = false
            local check = parent
            while check do
                if check:type() == "compound_statement" then
                    is_inside_func = true
                    break
                end
                check = check:parent()
            end
            if is_inside_func then
                local type_text = vim.treesitter.get_node_text(type_node, bufnr)
                local name_text = vim.treesitter.get_node_text(name_node, bufnr)
                local value_text = vim.treesitter.get_node_text(value_node, bufnr)
                local start_row, start_col, end_row, end_col = decl_node:range()
                local line_content = vim.api.nvim_buf_get_lines(bufnr, start_row, start_row + 1, false)[1]
                local indent = line_content:match("^%s*") or ""
                table.insert(changes, {
                    start_row = start_row,
                    start_col = start_col,
                    end_row = end_row,
                    end_col = end_col,
                    new_text = { type_text .. " " .. name_text .. ";", "", indent .. name_text .. " = " .. value_text .. ";" }
                })
            end
        end
    end
    for i = #changes, 1, -1 do
        local c = changes[i]
        pcall(vim.api.nvim_buf_set_text, bufnr, c.start_row, c.start_col, c.end_row, c.end_col, c.new_text)
    end
end

local function fix_norm_semantics()
    local bufnr = vim.api.nvim_get_current_buf()
    local parser = vim.treesitter.get_parser(bufnr, "c")
    if not parser then return end
    local tree = parser:parse()[1]
    local root = tree:root()

    -- 1. NO_ARGS_VOID
    local void_query = vim.treesitter.query.parse("c", [[
        (function_definition
            declarator: (function_declarator
                parameters: (parameter_list) @params))
    ]])
    local void_changes = {}
    for _, match, _ in void_query:iter_matches(root, bufnr, 0, -1) do
        local node = match[1]
        if node:child_count() == 2 then
            local s_r, s_c, e_r, e_c = node:range()
            table.insert(void_changes, { s_r, s_c, e_r, e_c, { "(void)" } })
        end
    end

    -- 2. RETURN_PARENTHESIS
    local ret_query = vim.treesitter.query.parse("c", [[ (return_statement (_)) @ret ]])
    local ret_changes = {}
    for _, match, _ in ret_query:iter_matches(root, bufnr, 0, -1) do
        local node = match[1]
        local text = vim.treesitter.get_node_text(node, bufnr)
        if text:match("^return%s+[^%(].*;$") then
            local val = text:match("^return%s+(.*);$")
            if val and val ~= "" then
                local s_r, s_c, e_r, e_c = node:range()
                table.insert(ret_changes, { s_r, s_c, e_r, e_c, { "return (" .. val .. ");" } })
            end
        end
    end

    local all = {}
    for _, c in ipairs(void_changes) do table.insert(all, c) end
    for _, c in ipairs(ret_changes) do table.insert(all, c) end
    table.sort(all, function(a, b) return a[1] > b[1] or (a[1] == b[1] and a[2] > b[2]) end)
    for _, c in ipairs(all) do
        pcall(vim.api.nvim_buf_set_text, bufnr, c[1], c[2], c[3], c[4], c[5])
    end
end

function M.format()
    -- Step 1: Standardize with clang-format first
    if vim.fn.executable("clang-format") == 1 then
        local view = vim.fn.winsaveview()
        -- Use style that doesn't break return types
        local cmd = "silent! %!clang-format --style='{BasedOnStyle: LLVM, UseTab: Always, TabWidth: 4, IndentWidth: 4, BreakBeforeBraces: Allman, AllowShortIfStatementsOnASingleLine: false, ColumnLimit: 80, AlwaysBreakAfterReturnType: None}'"
        vim.cmd(cmd)
        vim.fn.winrestview(view)
    end

    -- Step 2: Semantic transformations (must happen after clang-format to not get overwritten)
    split_initializations()
    fix_norm_semantics()

    -- Step 3: Specific 42 Spacing (Tab between type and function name)
    local bufnr = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local changed = false
    for i, line in ipairs(lines) do
        -- Fix MISSING_TAB_FUNC
        if line:match("^[%a%s%*]+%s+[%a_][%a%d_]*%s*%b()") and not line:match(";") and not line:match("^%s") then
            local type, name = line:match("^([%a%s%*]-)%s+([%a_][%a%d_]*%s*%b().*)")
            if type and name then
                lines[i] = type .. "\t" .. name
                changed = true
            end
        end
        -- Fix multiple empty lines
        if i > 1 and lines[i]:match("^%s*$") and lines[i-1]:match("^%s*$") then
            -- We'll handle this in a separate pass to avoid index issues
        end
    end
    
    -- Step 4: Spacing cleanup pass
    local final_lines = {}
    local last_was_empty = false
    for _, line in ipairs(lines) do
        local is_empty = line:match("^%s*$")
        if not (is_empty and last_was_empty) then
            table.insert(final_lines, line)
        end
        last_was_empty = is_empty
    end
    
    -- Remove empty line at start of function (just after brace)
    for i = 1, #final_lines - 1 do
        if final_lines[i]:match("^{%s*$") and final_lines[i+1]:match("^%s*$") then
            table.remove(final_lines, i+1)
        end
    end

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, final_lines)
end

return M
