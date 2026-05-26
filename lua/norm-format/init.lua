local M = {}

function M.setup(opts)
    opts = opts or {}
    local format_on_save = opts.format_on_save ~= false

    if format_on_save then
        local group = vim.api.nvim_create_augroup("NormFormat", { clear = true })
        vim.api.nvim_create_autocmd("BufWritePre", {
            group = group,
            pattern = { "*.c", "*.h" },
            callback = function()
                M.format()
            end,
        })
    end
end

-- Helper to split declarations (e.g., int i = 0; -> int i;\n\ni = 0;)
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

-- Fix common spacing/empty line norm errors
local function fix_norm_spacing()
    local bufnr = vim.api.nvim_get_current_buf()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local new_lines = {}
    local skip_next_empty = false

    for i, line in ipairs(lines) do
        local is_empty = line:match("^%s*$")
        
        -- 1. Remove multiple consecutive empty lines
        if is_empty then
            if not skip_next_empty then
                table.insert(new_lines, "")
                skip_next_empty = true
            end
        else
            table.insert(new_lines, line)
            skip_next_empty = false
        end
    end

    -- 2. Remove empty lines at the very beginning/end of function bodies
    -- This is a bit complex for regex, but we can do a simple trim for the whole file first
    while #new_lines > 0 and new_lines[1]:match("^%s*$") do
        table.remove(new_lines, 1)
    end
    while #new_lines > 0 and new_lines[#new_lines]:match("^%s*$") do
        table.remove(new_lines, #new_lines)
    end

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, new_lines)
end

function M.format()
    -- 1. Semantic split (declarations)
    pcall(split_initializations)

    -- 2. Fix easy norm spacing (multiple empty lines, etc)
    pcall(fix_norm_spacing)

    -- 3. Clang format (Indentation and alignment)
    if vim.fn.executable("clang-format") == 1 then
        local view = vim.fn.winsaveview()
        -- Force tabs and 4-width even if .clang-format is missing or wrong
        local cmd = "silent! %!clang-format --style='{BasedOnStyle: LLVM, UseTab: Always, TabWidth: 4, IndentWidth: 4, BreakBeforeBraces: Allman, AllowShortIfStatementsOnASingleLine: false, ColumnLimit: 80}'"
        vim.cmd(cmd)
        vim.fn.winrestview(view)
    end
end

return M
