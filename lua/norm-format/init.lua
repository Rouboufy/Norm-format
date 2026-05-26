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

local function is_in_header(line_idx)
    return line_idx < 12
end

function M.format()
    local bufnr = vim.api.nvim_get_current_buf()
    local header_lines = vim.api.nvim_buf_get_lines(bufnr, 0, 12, false)

    -- Step 1: Alignment pass
    if vim.fn.executable("clang-format") == 1 then
        local view = vim.fn.winsaveview()
        local cmd = "silent! %!clang-format --style='{BasedOnStyle: LLVM, UseTab: Always, TabWidth: 4, IndentWidth: 4, BreakBeforeBraces: Allman, AllowShortIfStatementsOnASingleLine: false, ColumnLimit: 80, AlwaysBreakAfterReturnType: None}'"
        vim.cmd(cmd)
        vim.fn.winrestview(view)
    end

    -- Step 2: Line-by-Line Logic
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local result = {}
    local in_function = false
    
    for i, line in ipairs(lines) do
        local line_idx = i - 1
        
        if is_in_header(line_idx) then
            table.insert(result, header_lines[i] or line)
        else
            -- A. Trim and Tab-ify Indentation
            line = line:gsub("%s+$", "") -- Trailing
            
            -- Force TABS for indentation
            while line:match("^%t*    ") do
                line = line:gsub("^(%t*)    ", "%1\t")
            end
            
            -- B. Semantic Fixes
            if line:match("%s[%a_][%a%d_]*%(%)") or line:match("^[%a_][%a%d_]*%(%)") then
                 line = line:gsub("%(%)", "(void)")
            end
            if line:match("^%s*return%s+[^%(].*;$") then
                local indent, val = line:match("^(%s*)return%s+(.-);$")
                if val and val ~= "" and not val:match("^%b()$") then
                    line = indent .. "return (" .. val .. ");"
                end
            end

            -- C. Type-Name Tabbing (IMPROVED REGEX)
            -- This catches "int var;" and replaces the space with a Tab.
            -- 42 Norm: MUST use Tab between type and name.
            if not line:match("^#") and not line:match("^{") and not line:match("^}") then
                -- Match: [indent] [type words] [spaces] [name/ptr]
                local indent, type, name_part = line:match("^([%t%s]*)([%a_][%a%d_%*]*.-)%s+([%a_%*].*)")
                if indent and type and name_part then
                    line = indent .. type .. "\t" .. name_part
                end
            end
            
            -- D. Empty Line Logic
            if line:match("^{") then in_function = true end
            if line:match("^}") then in_function = false end
            
            local is_empty = line:match("^%s*$")
            local skip = false
            
            if in_function and is_empty then
                local prev = i > 1 and result[#result] or ""
                local next = i < #lines and lines[i+1] or ""
                if prev:match("^{") or next:match("^}") then
                    skip = true
                end
            end
            
            if is_empty and #result > 0 and result[#result] == "" then
                skip = true
            end

            if not skip then
                table.insert(result, line)
            end
        end
    end

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, result)
end

return M
