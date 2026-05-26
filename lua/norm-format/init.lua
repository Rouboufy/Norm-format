local M = {}

function M.setup(opts)
    opts = opts or {}
    local format_on_save = opts.format_on_save ~= false

    if format_on_save then
        vim.api.nvim_create_autocmd("BufWritePre", {
            pattern = "*.c,*.h",
            callback = function()
                M.format()
            end,
        })
    end
end

function M.format()
    -- Ensure clang-format is available
    if vim.fn.executable("clang-format") == 0 then
        vim.notify("clang-format not found", vim.log.levels.ERROR)
        return
    end

    -- Use the .clang-format file if it exists, otherwise use a default 42-style
    local view = vim.fn.winsaveview()
    vim.cmd("%!clang-format")
    vim.fn.winrestview(view)
end

return M
