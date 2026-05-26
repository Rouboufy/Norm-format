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

function M.format()
    local bufnr = vim.api.nvim_get_current_buf()

    -- 1. Clang format
    if vim.fn.executable("clang-format") == 1 then
        local view = vim.fn.winsaveview()
        local cmd = "silent! %!clang-format --style='{BasedOnStyle: LLVM, UseTab: Always, TabWidth: 4, IndentWidth: 4, BreakBeforeBraces: Allman, AllowShortIfStatementsOnASingleLine: false, ColumnLimit: 80, AlwaysBreakAfterReturnType: None}'"
        vim.cmd(cmd)
        vim.fn.winrestview(view)
    end

    -- 2. Semantic split
    split_initializations()

    -- 3. Final cleanup pass
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local result = {}
    local in_function = false
    local after_declarations = false
    
    for i, line in ipairs(lines) do
        -- A. Trim trailing spaces
        line = line:gsub("%s+$", "")

        -- B. Fix NO_ARGS_VOID
        if line:match("%s[%a_][%a%d_]*%(%)") or line:match("^[%a_][%a%d_]*%(%)") then
             line = line:gsub("%(%)", "(void)")
        end

        -- C. Fix RETURN_PARENTHESIS
        if line:match("^%s*return%s+[^%(].*;$") then
            local indent, val = line:match("^(%s*)return%s+(.-);$")
            if val and val ~= "" and not val:match("^%b()$") then
                line = indent .. "return (" .. val .. ");"
            end
        end

        -- D. Fix MISSING_TAB_FUNC
        if line:match("^[%a_][%a%d_%*]+%s+[%a_][%a%d_]*%s*%b()") and not line:match(";") and not line:match("^%s") then
            local type, name = line:match("^([%a_][%a%d_%*]-)%s+([%a_][%a%d_]*%s*%b().*)")
            if type and name then
                line = type .. "\t" .. name
            end
        end
        
        -- E. Indentation: Replace ANY 4-space sequence with Tab
        line = line:gsub("    ", "\t")
        
        -- F. Empty line logic
        if line:match("^{") then in_function = true after_declarations = false end
        if line:match("^}") then in_function = false end
        
        local is_empty = line == ""
        local skip = false
        
        if in_function then
            -- Is this a declaration block?
            local is_decl = line:match("^%t*[%a_][%a%d_%*]*%s+[%a_][%a%d_]*%s*;")
            if is_decl then
                after_declarations = false
            elseif not is_empty and not line:match("^{") then
                after_declarations = true
            end
            
            -- Remove empty line if it's NOT the one between decls and code
            if is_empty then
                local prev = i > 1 and lines[i-1] or ""
                local next = i < #lines and lines[i+1] or ""
                
                -- Check if previous line was a declaration and next is not
                local prev_is_decl = prev:match(";%s*$") and not prev:match("return")
                local next_is_not_decl = not next:match("^%t*[%a_][%a%d_%*]*%s+[%a_][%a%d_]*%s*;")
                
                if not (prev_is_decl and next_is_not_decl) then
                    skip = true
                end
                
                -- Always skip empty line at start/end of function
                if prev:match("^{") or next:match("^}") then
                    skip = true
                end
            end
        end
        
        -- Global: Multiple empty lines
        if is_empty and i > 1 and result[#result] == "" then
            skip = true
        end

        if not skip then
            table.insert(result, line)
        end
    end

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, result)
end

return M
