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
                    -- Use Tabs between type and name for Norm compliance
                    new_text = { type_text .. "\t" .. name_text .. ";", "", indent .. name_text .. " = " .. value_text .. ";" }
                })
            end
        end
    end
    for i = #changes, 1, -1 do
        local c = changes[i]
        pcall(vim.api.nvim_buf_set_text, bufnr, c.start_row, c.start_col, c.end_row, c.end_col, c.new_text)
    end
end

function M.format()
    local bufnr = vim.api.nvim_get_current_buf()

    -- 1. Clang format (Alignment pass)
    if vim.fn.executable("clang-format") == 1 then
        local view = vim.fn.winsaveview()
        local cmd = "silent! %!clang-format --style='{BasedOnStyle: LLVM, UseTab: Always, TabWidth: 4, IndentWidth: 4, BreakBeforeBraces: Allman, AllowShortIfStatementsOnASingleLine: false, ColumnLimit: 80, AlwaysBreakAfterReturnType: None}'"
        vim.cmd(cmd)
        vim.fn.winrestview(view)
    end

    -- 2. Semantic split
    split_initializations()

    -- 3. Final Norm logic pass
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local result = {}
    local in_function = false
    
    for i, line in ipairs(lines) do
        line = line:gsub("%s+$", "") -- Trim trailing
        
        -- Fix NO_ARGS_VOID
        if line:match("%s[%a_][%a%d_]*%(%)") or line:match("^[%a_][%a%d_]*%(%)") then
             line = line:gsub("%(%)", "(void)")
        end

        -- Fix RETURN_PARENTHESIS
        if line:match("^%s*return%s+[^%(].*;$") then
            local indent, val = line:match("^(%s*)return%s+(.-);$")
            if val and val ~= "" and not val:match("^%b()$") then
                line = indent .. "return (" .. val .. ");"
            end
        end

        -- Fix TABS between Type and Name (Functions & Variables)
        -- Match: [indent]type name[; or (]
        if line:match("^[%t%s]*[%a_][%a%d_%*]*%s+[%a_][%a%d_]*[%s;%(]") then
             local indent, type, rest = line:match("^([%t%s]*)([%a_][%a%d_%*]*.-)%s+([%a_][%a%d_]*.*)")
             if indent and type and rest then
                 line = indent .. type .. "\t" .. rest
             end
        end
        
        -- Indentation: Force Tabs
        line = line:gsub("    ", "\t")
        
        if line:match("^{") then in_function = true end
        if line:match("^}") then in_function = false end
        
        local is_empty = line == ""
        local skip = false
        
        if in_function and is_empty then
            local prev = i > 1 and lines[i-1] or ""
            local next = i < #lines and lines[i+1] or ""
            
            -- Keep empty line ONLY if it separates decls from code
            local prev_is_decl = prev:match(";%s*$") and not prev:match("return")
            local next_is_not_decl = not next:match("^%t*[%a_][%a%d_%*]*%s+[%a_][%a%d_]*%s*;")
            
            if not (prev_is_decl and next_is_not_decl) then
                skip = true
            end
            if prev:match("^{") or next:match("^}") then skip = true end
        end
        
        if is_empty and #result > 0 and result[#result] == "" then skip = true end

        if not skip then table.insert(result, line) end
    end

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, result)
end

return M
