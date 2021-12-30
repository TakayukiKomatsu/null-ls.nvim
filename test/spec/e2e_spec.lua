local builtins = require("null-ls.builtins")
local methods = require("null-ls.methods")
local sources = require("null-ls.sources")
local main = require("null-ls")

local c = require("null-ls.config")
local u = require("null-ls.utils")
local s = require("null-ls.state")
local tu = require("test.utils")

local lsp = vim.lsp
local api = vim.api

-- need to wait for most LSP commands to pass through the client
-- setting this lower reduces testing time but is more likely to cause failures
local lsp_wait = function(wait_time)
    vim.wait(wait_time or 400)
end

main.setup({ log = { enable = false } })

local get_code_actions = function()
    local current_bufnr = api.nvim_get_current_buf()
    return lsp.buf_request_sync(
        current_bufnr,
        methods.lsp.CODE_ACTION,
        { textDocument = { uri = vim.uri_from_bufnr(current_bufnr) } }
    )
end

describe("e2e", function()
    after_each(function()
        vim.cmd("bufdo! bdelete!")

        c.reset()
        s.reset()
        sources.reset()
    end)

    describe("code actions", function()
        local actions, null_ls_action
        before_each(function()
            sources.register(builtins._test.toggle_line_comment)

            tu.edit_test_file("test-file.lua")
            lsp_wait(0)

            actions = get_code_actions()
            null_ls_action = actions[1].result[1]
        end)

        after_each(function()
            actions = nil
            null_ls_action = nil
        end)

        it("should get code action", function()
            assert.equals(vim.tbl_count(actions[1].result), 1)

            assert.equals(null_ls_action.title, "Comment line")
            assert.equals(null_ls_action.command, methods.internal.CODE_ACTION)
        end)

        it("should apply code action", function()
            vim.lsp.buf.execute_command(null_ls_action)

            assert.equals(u.buf.content(nil, true), '--print("I am a test file!")\n')
        end)

        it("should adapt code action based on params", function()
            vim.lsp.buf.execute_command(null_ls_action)

            actions = get_code_actions()
            null_ls_action = actions[1].result[1]
            assert.equals(null_ls_action.title, "Uncomment line")

            vim.lsp.buf.execute_command(null_ls_action)
            assert.equals(u.buf.content(nil, true), 'print("I am a test file!")\n')
        end)

        it("should combine actions from multiple sources", function()
            sources.register(builtins._test.mock_code_action)

            actions = get_code_actions()

            assert.equals(vim.tbl_count(actions[1].result), 2)
        end)

        it("should handle code action timeout", function()
            -- action calls a script that waits for 250 ms,
            -- but action timeout is 100 ms
            sources.register(builtins._test.slow_code_action)

            actions = get_code_actions()

            assert.equals(vim.tbl_count(actions[1].result), 1)
        end)
    end)

    describe("diagnostics", function()
        if not u.is_executable("write-good") then
            print("skipping diagnostic tests (write-good not installed)")
            return
        end

        before_each(function()
            sources.register(builtins.diagnostics.write_good)

            tu.edit_test_file("test-file.md")
            lsp_wait()
        end)

        it("should get buffer diagnostics on attach", function()
            local buf_diagnostics = vim.diagnostic.get(0)
            assert.equals(vim.tbl_count(buf_diagnostics), 1)

            local write_good_diagnostic = buf_diagnostics[1]
            assert.equals(write_good_diagnostic.message, '"really" can weaken meaning')
            assert.equals(write_good_diagnostic.source, "write-good")
            assert.equals(write_good_diagnostic.lnum, 0)
            assert.equals(write_good_diagnostic.end_lnum, 0)
            assert.equals(write_good_diagnostic.col, 7)
            assert.equals(write_good_diagnostic.end_col, 13)
        end)

        it("should clear and regenerate buffer diagnostics on toggle", function()
            sources.toggle("write-good")

            assert.equals(vim.tbl_count(vim.diagnostic.get(0)), 0)

            sources.toggle("write-good")
            lsp_wait()

            assert.equals(vim.tbl_count(vim.diagnostic.get(0)), 1)
        end)

        it("should update buffer diagnostics on text change", function()
            -- remove "really"
            api.nvim_buf_set_text(api.nvim_get_current_buf(), 0, 6, 0, 13, {})
            lsp_wait()

            assert.equals(vim.tbl_count(vim.diagnostic.get(0)), 0)
        end)

        describe("multiple diagnostics", function()
            if not u.is_executable("markdownlint") then
                print("skipping multiple diagnostics tests (markdownlint not installed)")
                return
            end

            it("should show diagnostics from multiple sources", function()
                sources.register(builtins.diagnostics.markdownlint)
                vim.cmd("e")
                lsp_wait()

                local diagnostics = vim.diagnostic.get(0)
                assert.equals(vim.tbl_count(diagnostics), 2)

                local markdownlint_diagnostic, write_good_diagnostic
                for _, diagnostic in ipairs(diagnostics) do
                    if diagnostic.source == "markdownlint" then
                        markdownlint_diagnostic = diagnostic
                    end
                    if diagnostic.source == "write-good" then
                        write_good_diagnostic = diagnostic
                    end
                end
                assert.truthy(markdownlint_diagnostic)
                assert.truthy(write_good_diagnostic)
            end)
        end)

        describe("multiple-file diagnostics", function()
            it("should set diagnostics for multiple files", function()
                sources.reset()
                sources.register(builtins._test.mock_multiple_file_diagnostics)
                vim.cmd("e")
                lsp_wait()

                local diagnostics = vim.diagnostic.get()
                assert.equals(vim.tbl_count(diagnostics), 2)

                local lua_diagnostic, javascript_diagnostic
                for _, diagnostic in ipairs(diagnostics) do
                    if diagnostic.filename == tu.test_file_path("test-file.lua") then
                        lua_diagnostic = diagnostic
                    end
                    if diagnostic.filename == tu.test_file_path("test-file.js") then
                        javascript_diagnostic = diagnostic
                    end
                end
                assert.truthy(lua_diagnostic)
                assert.is_not.equals(lua_diagnostic.bufnr, api.nvim_get_current_buf())
                assert.truthy(javascript_diagnostic)
                assert.is_not.equals(javascript_diagnostic.bufnr, api.nvim_get_current_buf())
            end)
        end)

        it("should format diagnostics with source-specific diagnostics_format", function()
            sources.reset()
            sources.register(builtins.diagnostics.write_good.with({ diagnostics_format = "#{m} (#{s})" }))
            vim.cmd("e")
            lsp_wait()

            local write_good_diagnostic = vim.diagnostic.get(0)[1]

            assert.equals(write_good_diagnostic.message, '"really" can weaken meaning (write-good)')
        end)
    end)

    describe("formatting", function()
        if not u.is_executable("prettier") then
            print("skipping formatting tests (prettier not installed)")
            return
        end

        local formatted = 'import { User } from "./test-types";\n'

        before_each(function()
            sources.register(builtins.formatting.prettier)

            tu.edit_test_file("test-file.js")
            -- make sure file wasn't accidentally saved
            assert.is_not.equals(u.buf.content(nil, true), formatted)

            lsp_wait()
        end)

        it("should format file", function()
            lsp.buf.formatting()
            lsp_wait(500)

            assert.equals(u.buf.content(nil, true), formatted)
        end)

        describe("from_temp_file", function()
            local prettier = builtins.formatting.prettier
            local original_args = prettier._opts.args
            before_each(function()
                sources.reset()

                prettier._opts.args = { "--write", "$FILENAME" }
                prettier._opts.to_temp_file = true
                sources.register(prettier)
            end)
            after_each(function()
                prettier._opts.args = original_args
                prettier._opts.from_temp_file = nil
                prettier._opts.to_temp_file = nil
            end)

            it("should format file", function()
                lsp.buf.formatting()
                lsp_wait(800)

                assert.equals(u.buf.content(nil, true), formatted)
            end)
        end)
    end)

    describe("range formatting", function()
        if not u.is_executable("prettier") then
            print("skipping range formatting tests (prettier not installed)")
            return
        end

        -- only first line should be formatted
        local formatted = 'import { User } from "./test-types";\nimport {Other} from "./test-types"\n'

        before_each(function()
            sources.register(builtins.formatting.prettier)
            tu.edit_test_file("range-formatting.js")
            assert.is_not.equals(u.buf.content(nil, true), formatted)

            lsp_wait()
        end)

        it("should format specified range", function()
            vim.cmd("normal ggV")

            lsp.buf.range_formatting()
            lsp_wait(500)

            assert.equals(u.buf.content(nil, true), formatted)
        end)
    end)

    describe("temp file source", function()
        if not u.is_executable("tl") then
            print("skipping temp file source tests (teal not installed)")
            return
        end

        before_each(function()
            api.nvim_exec(
                [[
            augroup NullLsTesting
                autocmd!
                autocmd BufEnter *.tl set filetype=teal
            augroup END
            ]],
                false
            )
            sources.register(builtins.diagnostics.teal)

            tu.edit_test_file("test-file.tl")
            lsp_wait()
        end)
        after_each(function()
            api.nvim_exec(
                [[
            augroup NullLsTesting
                autocmd!
            augroup END
            ]],
                false
            )
            vim.cmd("augroup! NullLsTesting")
        end)

        it("should handle source that uses temp file", function()
            -- replace - with .., which will mess up the return type
            api.nvim_buf_set_text(api.nvim_get_current_buf(), 0, 52, 0, 53, { ".." })
            lsp_wait()

            local buf_diagnostics = vim.diagnostic.get(0)
            assert.equals(vim.tbl_count(buf_diagnostics), 1)

            local tl_check_diagnostic = buf_diagnostics[1]
            assert.equals(tl_check_diagnostic.message, "in return value: got string, expected number")
            assert.equals(tl_check_diagnostic.source, "tl check")
            assert.equals(tl_check_diagnostic.lnum, 0)
            assert.equals(tl_check_diagnostic.end_lnum, 1)
            assert.equals(tl_check_diagnostic.col, 52)
            assert.equals(tl_check_diagnostic.end_col, 0)
        end)
    end)

    describe("cached generator", function()
        local actions, null_ls_action
        before_each(function()
            sources.register(builtins._test.cached_code_action)
            tu.edit_test_file("test-file.txt")
            lsp_wait(0)

            actions = get_code_actions()
            null_ls_action = actions[1].result[1]
        end)
        after_each(function()
            actions = nil
            null_ls_action = nil
        end)

        it("should cache results after running action once", function()
            assert.equals(null_ls_action.title, "Not cached")

            actions = get_code_actions()
            null_ls_action = actions[1].result[1]

            assert.equals(null_ls_action.title, "Cached")
        end)

        it("should reset cache when file is edited", function()
            assert.equals(null_ls_action.title, "Not cached")

            api.nvim_buf_set_lines(0, 0, 1, false, { "print('new content')" })
            lsp_wait(0)

            actions = get_code_actions()
            null_ls_action = actions[1].result[1]
            assert.equals(null_ls_action.title, "Not cached")
        end)
    end)

    describe("local executable", function()
        before_each(function()
            sources._reset()
            tu.edit_test_file("test-file.lua")
        end)

        describe("prefer_local", function()
            it("should prefer local executable when available", function()
                local copy = builtins._test.slow_code_action.with({
                    command = "cat",
                    args = {},
                    prefer_local = true,
                })
                sources.register(copy)
                lsp_wait(0)

                local actions = get_code_actions()
                lsp_wait(0)

                assert.equals(vim.tbl_count(actions[1].result), 1)
                assert.equals(copy._opts._last_command, tu.test_dir .. "/files/cat")
                assert.equals(copy._opts._last_cwd, tu.test_dir .. "/files")
            end)

            it("should fall back to global executable when local is unavailable", function()
                local copy = builtins._test.slow_code_action.with({
                    command = "ls",
                    args = {},
                    prefer_local = true,
                })
                sources.register(copy)
                lsp_wait(0)

                local actions = get_code_actions()
                lsp_wait(0)

                assert.equals(vim.tbl_count(actions[1].result), 1)
                assert.equals(copy._opts._last_command, "ls")
                assert.equals(copy._opts._last_cwd, vim.loop.cwd())
            end)
        end)

        describe("only_local", function()
            it("should use local executable when available", function()
                local copy = builtins._test.slow_code_action.with({
                    command = "cat",
                    args = {},
                    only_local = true,
                })
                sources.register(copy)
                lsp_wait(0)

                local actions = get_code_actions()
                lsp_wait(0)

                assert.equals(vim.tbl_count(actions[1].result), 1)
                assert.equals(copy._opts._last_command, tu.test_dir .. "/files/cat")
                assert.equals(copy._opts._last_cwd, tu.test_dir .. "/files")
            end)

            it("should not run when local executable is unavailable", function()
                local copy = builtins._test.slow_code_action.with({
                    command = "ls",
                    args = {},
                    only_local = true,
                })
                sources.register(copy)
                lsp_wait(0)

                local actions = get_code_actions()
                lsp_wait(0)

                assert.equals(vim.tbl_count(actions[1].result), 0)
                assert.equals(copy._opts.last_command, nil)
                assert.equals(copy._opts._last_cwd, nil)
            end)
        end)
    end)

    describe("sequential formatting", function()
        it("should format file sequentially", function()
            sources.register(builtins._test.first_formatter)
            sources.register(builtins._test.second_formatter)
            tu.edit_test_file("test-file.txt")
            lsp_wait(0)

            lsp.buf.formatting()
            lsp_wait(100)

            assert.equals(u.buf.content(nil, true), "sequential\n")
        end)

        it("should only create one undo step", function()
            sources.register(builtins._test.first_formatter)
            sources.register(builtins._test.second_formatter)
            tu.edit_test_file("test-file.txt")
            lsp_wait(0)
            lsp.buf.formatting()
            lsp_wait(100)

            vim.cmd("silent normal u")

            assert.equals(u.buf.content(nil, true), "intentionally left blank\n")
        end)

        it("should format file according to source order", function()
            sources.register(builtins._test.second_formatter)
            sources.register(builtins._test.first_formatter)
            tu.edit_test_file("test-file.txt")
            lsp_wait(0)

            lsp.buf.formatting()
            lsp_wait(100)

            assert.equals(u.buf.content(nil, true), "first\n")
        end)
    end)

    describe("conditions", function()
        it("should register and run formatter that passes condition", function()
            sources.register(builtins._test.first_formatter.with({
                condition = function()
                    return true
                end,
            }))
            tu.edit_test_file("test-file.txt")
            lsp_wait(0)

            lsp.buf.formatting()
            lsp_wait(50)

            assert.equals(#sources.get({}), 1)
            assert.equals(u.buf.content(nil, true), "first\n")
        end)

        it("should deregister and not run formatter that fails condition", function()
            sources.register(builtins._test.first_formatter.with({
                condition = function()
                    return false
                end,
            }))
            tu.edit_test_file("test-file.txt")
            lsp_wait(0)

            lsp.buf.formatting()
            lsp_wait(50)

            assert.equals(#sources.get({}), 0)
            assert.equals(u.buf.content(nil, true), "intentionally left blank\n")
        end)

        it("should skip source that fails runtime condition", function()
            sources.register(builtins._test.first_formatter)
            sources.register(builtins._test.second_formatter.with({
                runtime_condition = function()
                    return false
                end,
            }))
            tu.edit_test_file("test-file.txt")
            lsp_wait()

            lsp.buf.formatting()
            lsp_wait(100)

            assert.equals(#sources.get({}), 2)
            assert.equals(u.buf.content(nil, true), "first\n")
        end)
    end)

    describe("handlers", function()
        local mock_handler = require("luassert.stub").new()
        before_each(function()
            local client = require("null-ls.client").get_client()
            client.handlers[methods.lsp.FORMATTING] = mock_handler

            sources.register(builtins._test.first_formatter)
            tu.edit_test_file("test-file.txt")
            lsp_wait(0)
        end)
        after_each(function()
            require("null-ls.client").get_client().handlers[methods.lsp.CODE_ACTION] = nil
        end)

        it("should use client handler", function()
            lsp.buf.formatting()
            lsp_wait(50)

            assert.stub(mock_handler).was_called()
        end)
    end)

    describe("hover", function()
        local mock_handler = require("luassert.stub").new()

        before_each(function()
            sources.register(builtins._test.mock_hover)
            tu.edit_test_file("test-file.txt")
            lsp_wait(0)

            local client = require("null-ls.client").get_client()
            client.handlers[methods.lsp.HOVER] = mock_handler
        end)
        after_each(function()
            require("null-ls.client").get_client().handlers[methods.lsp.HOVER] = nil
        end)

        it("should call handler with results", function()
            vim.lsp.buf.hover()
            lsp_wait(0)

            assert.stub(mock_handler).was_called()
            assert.same(mock_handler.calls[1].refs[2], { contents = { { "test" } } })
        end)
    end)

    describe("client", function()
        it("should not leave pending requests on client object", function()
            local client = require("null-ls.client").get_client()

            assert.truthy(client)
            assert.truthy(vim.tbl_isempty(client.requests))
        end)
    end)
end)
