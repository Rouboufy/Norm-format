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
    local seen_declaration = false
    
    for i, line in ipairs(lines) do
        -- A. Fix NO_ARGS_VOID: int main() -> int main(void)
        if line:match("%s[%a_][%a%d_]*%(%)") or line:match("^[%a_][%a%d_]*%(%)") then
             line = line:gsub("%(%)", "(void)")
        end

        -- B. Fix RETURN_PARENTHESIS
        if line:match("^%s*return%s+[^%(].*;$") then
            local indent, val = line:match("^(%s*)return%s+(.-);$")
            if val and val ~= "" and not val:match("^%b()$") then
                line = indent .. "return (" .. val .. ");"
            end
        end

        -- C. Fix MISSING_TAB_FUNC
        if line:match("^[%a_][%a%d_%*]+%s+[%a_][%a%d_]*%s*%b()") and not line:match(";") and not line:match("^%s") then
            local type, name = line:match("^([%a_][%a%d_%*]-)%s+([%a_][%a%d_]*%s*%b().*)")
            if type and name then
                line = type .. "\t" .. name
            end
        end
        
        -- D. Fix Leading Spaces (replace all 4-space indents with Tabs)
        while line:match("^%t*    ") do
            line = line:gsub("^(%t*)    ", "%1\t")
        end
        
        -- E. Detect function context for empty line rules
        if line:match("^{%s*$") then in_function = true seen_declaration = false end
        if line:match("^}%s*$") then in_function = false end
        
        if in_function then
            -- Is this a declaration?
            if line:match("^%t*[%a_][%a%d_%*]*%s+[%a_][%a%d_]*%s*;") then
                seen_declaration = true
            end
        end

        table.insert(result, line)
    end
    
    -- F. Remove illegal empty lines inside functions
    local final = {}
    for i = 1, #result do
        local skip = false
        local line = result[i]
        
        -- Multiple empty lines
        if line == "" and i > 1 and result[i-1] == "" then
            skip = true
        end
        
        -- Empty line after { or before }
        if line == "" and i > 1 and result[i-1]:match("^{") then skip = true end
        if line == "" and i < #result and result[i+1]:match("^}") then skip = true end
        
        -- Empty line between instructions (after the first block of declarations)
        -- We detect this if we are deep in a function and see an empty line
        -- Actually, the rule is: ONE empty line after all declarations.
        -- But for simplicity: let's remove ALL empty lines inside functions EXCEPT if the previous line was a declaration.
        if in_function and line == "" then
             -- (This is a bit aggressive, maybe just remove it if the previous line was NOT a declaration)
             local prev = result[i-1]
             if prev and not prev:match(";%s*$") and not prev:match("^{") then
                 -- This might be inside a control structure... let's be careful.
             end
        end

        if not skip then
            table.insert(final, line)
        end
    end

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, final)
end

return M
