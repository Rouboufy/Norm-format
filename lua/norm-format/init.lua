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

-- Helper to split declarations (e.g., int i = 0; -> int i;\ni = 0;)
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
            -- Split if inside a block {}
            while parent and parent:type() ~= "compound_statement" and parent:type() ~= "translation_unit" do
                parent = parent:parent()
            end
            
            if parent and parent:type() == "compound_statement" then
                local type_text = vim.treesitter.get_node_text(type_node, bufnr)
                local name_text = vim.treesitter.get_node_text(name_node, bufnr)
                local value_text = vim.treesitter.get_node_text(value_node, bufnr)
                
                local start_row, start_col, end_row, end_col = decl_node:range()
                
                -- Detect current line indentation (important for clang-format to not get confused)
                local line = vim.api.nvim_buf_get_lines(bufnr, start_row, start_row + 1, false)[1]
                local indent = line:match("^%s*") or ""
                
                table.insert(changes, {
                    start_row = start_row,
                    start_col = start_col,
                    end_row = end_row,
                    end_col = end_col,
                    new_text = { type_text .. " " .. name_text .. ";", indent .. name_text .. " = " .. value_text .. ";" }
                })
            end
        end
    end
    
    -- Apply changes in reverse order
    for i = #changes, 1, -1 do
        local c = changes[i]
        vim.api.nvim_buf_set_text(bufnr, c.start_row, c.start_col, c.end_row, c.end_col, c.new_text)
    end
end

function M.format()
    -- 1. Semantic split
    local split_status, split_err = pcall(split_initializations)
    if not split_status then
        vim.notify("Norm-format split failed: " .. tostring(split_err), vim.log.levels.ERROR)
    end

    -- 2. Clang format
    if vim.fn.executable("clang-format") == 1 then
        local view = vim.fn.winsaveview()
        vim.cmd("silent! %!clang-format")
        vim.fn.winrestview(view)
    else
        -- If clang-format is not in path, try looking in homebrew or local bin
        local brew_clang = "/home/linuxbrew/.linuxbrew/bin/clang-format"
        if vim.fn.executable(brew_clang) == 1 then
             local view = vim.fn.winsaveview()
             vim.cmd("silent! %!" .. brew_clang)
             vim.fn.winrestview(view)
        else
            vim.notify("clang-format not found in PATH or Homebrew", vim.log.levels.WARN)
        end
    end
end

return M
