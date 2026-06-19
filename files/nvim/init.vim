set number
set mouse=a
set termguicolors
set updatetime=250
set signcolumn=yes
set hidden
set clipboard=unnamedplus
set expandtab
set shiftwidth=4
set tabstop=4
set smartindent

let mapleader = " "

" Let terminal background show through
highlight Normal guibg=NONE ctermbg=NONE
highlight NormalNC guibg=NONE ctermbg=NONE
highlight SignColumn guibg=NONE ctermbg=NONE
highlight EndOfBuffer guibg=NONE ctermbg=NONE
highlight LineNr guibg=NONE ctermbg=NONE
highlight StatusLine guibg=NONE ctermbg=NONE
highlight StatusLineNC guibg=NONE ctermbg=NONE

call plug#begin('~/.local/share/nvim/plugged')

Plug 'neovim/nvim-lspconfig'
Plug 'hrsh7th/nvim-cmp'
Plug 'hrsh7th/cmp-nvim-lsp'
Plug 'hrsh7th/cmp-buffer'
Plug 'hrsh7th/cmp-path'
Plug 'L3MON4D3/LuaSnip'
Plug 'saadparwaiz1/cmp_luasnip'

Plug 'stevearc/conform.nvim'
Plug 'mfussenegger/nvim-lint'

Plug 'lewis6991/gitsigns.nvim'
Plug 'tpope/vim-fugitive'

Plug 'nvim-lua/plenary.nvim'
Plug 'ThePrimeagen/harpoon', { 'branch': 'harpoon2' }
Plug 'nvim-telescope/telescope.nvim'
Plug 'nvim-tree/nvim-tree.lua'
Plug 'nvim-lualine/lualine.nvim'

Plug 'mfussenegger/nvim-dap'
Plug 'mfussenegger/nvim-dap-python'
Plug 'nvim-neotest/nvim-nio'
Plug 'rcarriga/nvim-dap-ui'
Plug 'Vigemus/iron.nvim'

call plug#end()

nnoremap <leader>e :NvimTreeToggle<CR>
nnoremap <leader>ff :Telescope find_files<CR>
nnoremap <leader>fg :Telescope live_grep<CR>
nnoremap <leader>fb :Telescope buffers<CR>
nnoremap <leader>fh :Telescope help_tags<CR>
nnoremap <leader>E :NvimTreeFocus<CR>

nnoremap <leader>gs :Git<CR>
nnoremap <leader>gb :Git blame<CR>
nnoremap <leader>gd :Gdiffsplit<CR>
nnoremap <leader>fp :lua require('telescope.builtin').find_files({ cwd = vim.fn.expand('%:p:h') })<CR>
nnoremap <leader>f :lua require('conform').format({ async = true, lsp_fallback = true })<CR>
nnoremap <leader>l :lua require('lint').try_lint()<CR>
nnoremap <leader>d :lua vim.diagnostic.open_float()<CR>

nnoremap <M-h> <C-w>h
nnoremap <M-j> <C-w>j
nnoremap <M-k> <C-w>k
nnoremap <M-l> <C-w>l

tnoremap <M-h> <C-\><C-n><C-w>h
tnoremap <M-j> <C-\><C-n><C-w>j
tnoremap <M-k> <C-\><C-n><C-w>k
tnoremap <M-l> <C-\><C-n><C-w>l

xnoremap > :s/^/ /<CR>gv
xnoremap < :s/^ //<CR>gv
            
" Telescope resume
nnoremap <leader>fr :Telescope resume<CR>

" Focus terminal / Iron REPL window
function! FocusTerminalWindow()
  for win in range(1, winnr('$'))
    let bufnr = winbufnr(win)
    if getbufvar(bufnr, '&buftype') ==# 'terminal'
      execute win . 'wincmd w'
      return
    endif
  endfor
  echo "No terminal window found"
endfunction

nnoremap <leader>it :call FocusTerminalWindow()<CR>

function! OpenTermTreeLayout()
  leftabove vsplit
  terminal
  wincmd p
  NvimTreeOpen
  wincmd p
endfunction

nnoremap <leader>ot :call OpenTermTreeLayout()<CR>

lua << EOF
local cmp = require('cmp')
local luasnip = require('luasnip')

local iron = require('iron.core')
local view = require('iron.view')
local common = require('iron.fts.common')

-- -------------------------------------------------------------------
-- Harpoon quick file navigation
-- -------------------------------------------------------------------

local has_harpoon, harpoon = pcall(require, "harpoon")

if has_harpoon then
  harpoon:setup({
    settings = {
      save_on_toggle = true,
    },
  })

  vim.keymap.set("n", "<leader>ha", function()
    harpoon:list():add()
    print("Harpoon: added current file")
  end, { desc = "Harpoon add current file" })

  vim.keymap.set("n", "<leader>hm", function()
    harpoon.ui:toggle_quick_menu(harpoon:list())
  end, { desc = "Harpoon quick menu" })

  vim.keymap.set("n", "<leader>h1", function()
    harpoon:list():select(1)
  end, { desc = "Harpoon file 1" })

  vim.keymap.set("n", "<leader>h2", function()
    harpoon:list():select(2)
  end, { desc = "Harpoon file 2" })

  vim.keymap.set("n", "<leader>h3", function()
    harpoon:list():select(3)
  end, { desc = "Harpoon file 3" })

  vim.keymap.set("n", "<leader>h4", function()
    harpoon:list():select(4)
  end, { desc = "Harpoon file 4" })

  vim.keymap.set("n", "<leader>h5", function()
    harpoon:list():select(5)
  end, { desc = "Harpoon file 5" })

  vim.keymap.set("n", "<leader>hn", function()
    harpoon:list():next()
  end, { desc = "Harpoon next file" })

  vim.keymap.set("n", "<leader>hN", function()
    harpoon:list():prev()
  end, { desc = "Harpoon previous file" })
end

local theme_state_file = vim.fn.stdpath("state") .. "/theme_mode"

-- -------------------------------------------------------------------
-- Paste replacement
--
-- Workflow:
--   1. Visual-line select old block
--   2. <leader>pp
--   3. Ctrl+Shift+V into scratch buffer
--   4. Esc
--   5. <leader>pa
-- -------------------------------------------------------------------

local paste_replace_state = nil

local function leading_whitespace(line)
  return line:match("^%s*") or ""
end

local function indent_len(line)
  return #(line:match("^%s*") or "")
end

local function strip_first_line_indent(lines)
  local base_indent = nil

  for _, line in ipairs(lines) do
    if line:match("%S") then
      base_indent = indent_len(line)
      break
    end
  end

  if base_indent == nil or base_indent == 0 then
    return lines
  end

  local out = {}

  for _, line in ipairs(lines) do
    if line:match("%S") then
      local this_indent = indent_len(line)

      if this_indent >= base_indent then
        table.insert(out, line:sub(base_indent + 1))
      else
        -- Rare case: a later line is further left than the first pasted line.
        -- Leave it alone rather than guessing.
        table.insert(out, line)
      end
    else
      table.insert(out, "")
    end
  end

  return out
end

local function close_scratch_buffer(scratch_buf)
  if scratch_buf == nil or not vim.api.nvim_buf_is_valid(scratch_buf) then
    return
  end

  local scratch_win = vim.fn.bufwinid(scratch_buf)

  if scratch_win ~= -1 and vim.api.nvim_win_is_valid(scratch_win) then
    vim.api.nvim_set_current_win(scratch_win)
    vim.cmd("close")
  else
    vim.api.nvim_buf_delete(scratch_buf, { force = true })
  end
end

local function start_paste_replace(line1, line2)
  local start_line = tonumber(line1)
  local end_line = tonumber(line2)

  if start_line == nil or end_line == nil then
    print("Paste replacement: no range supplied")
    return
  end

  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end

  local source_buf = vim.api.nvim_get_current_buf()
  local source_win = vim.api.nvim_get_current_win()
  local line_count = vim.api.nvim_buf_line_count(source_buf)

  if start_line < 1 or end_line < 1 or start_line > line_count then
    print("Paste replacement: invalid selected range")
    return
  end

  end_line = math.min(end_line, line_count)

  -- Anchor pasted code to the indentation of the first selected line.
  -- The selected range only tells us what to delete.
  local first_selected_line = vim.api.nvim_buf_get_lines(
    source_buf,
    start_line - 1,
    start_line,
    false
  )[1] or ""

  local target_indent = leading_whitespace(first_selected_line)

  paste_replace_state = {
    source_buf = source_buf,
    source_win = source_win,
    start_line = start_line,
    end_line = end_line,
    target_indent = target_indent,
    changedtick = vim.b[source_buf].changedtick,
    scratch_buf = nil,
  }

  vim.cmd("botright new")
  local scratch_buf = vim.api.nvim_get_current_buf()

  paste_replace_state.scratch_buf = scratch_buf

  vim.bo[scratch_buf].buftype = "nofile"
  vim.bo[scratch_buf].bufhidden = "wipe"
  vim.bo[scratch_buf].swapfile = false
  vim.bo[scratch_buf].filetype = vim.bo[source_buf].filetype

  pcall(vim.api.nvim_buf_set_name, scratch_buf, "paste-replace-scratch")
  vim.api.nvim_buf_set_lines(scratch_buf, 0, -1, false, { "" })
  vim.api.nvim_win_set_cursor(0, { 1, 0 })

  print(
    string.format(
      "Paste replacement: replacing original lines %s-%s. Paste here, then Esc, then <leader>pa.",
      start_line,
      end_line
    )
  )

  vim.cmd("startinsert")
end

local function apply_paste_replace()
  if paste_replace_state == nil then
    print("Paste replacement: no active replacement")
    return
  end

  local state = paste_replace_state

  if not vim.api.nvim_buf_is_valid(state.source_buf) then
    print("Paste replacement: original buffer no longer exists")
    paste_replace_state = nil
    return
  end

  if not vim.api.nvim_buf_is_valid(state.scratch_buf) then
    print("Paste replacement: scratch buffer no longer exists")
    paste_replace_state = nil
    return
  end

  if vim.b[state.source_buf].changedtick ~= state.changedtick then
    print("Paste replacement: original buffer changed since selection; cancelling")
    close_scratch_buffer(state.scratch_buf)
    paste_replace_state = nil
    return
  end

  local lines = vim.api.nvim_buf_get_lines(state.scratch_buf, 0, -1, false)

  -- Remove trailing blank lines caused by terminal paste/newline.
  while #lines > 1 and lines[#lines] == "" do
    table.remove(lines)
  end

  if #lines == 0 or (#lines == 1 and lines[1] == "") then
    print("Paste replacement: scratch buffer is empty")
    return
  end

  -- Use the first non-blank pasted line as the base indent.
  -- Then preserve all indentation relative to that line.
  lines = strip_first_line_indent(lines)

  for i, line in ipairs(lines) do
    if line:match("%S") then
      lines[i] = state.target_indent .. line
    else
      lines[i] = ""
    end
  end

  local line_count = vim.api.nvim_buf_line_count(state.source_buf)
  local start_idx = math.max(0, math.min(state.start_line - 1, line_count))
  local end_idx = math.max(0, math.min(state.end_line, line_count))

  if start_idx > end_idx then
    end_idx = start_idx
  end

  vim.api.nvim_buf_set_lines(
    state.source_buf,
    start_idx,
    end_idx,
    false,
    lines
  )

  close_scratch_buffer(state.scratch_buf)

  if vim.api.nvim_win_is_valid(state.source_win) then
    vim.api.nvim_set_current_win(state.source_win)
  else
    vim.api.nvim_set_current_buf(state.source_buf)
  end

  local new_line_count = vim.api.nvim_buf_line_count(state.source_buf)
  local cursor_line = math.max(1, math.min(state.start_line, new_line_count))

  vim.api.nvim_win_set_cursor(0, {
    cursor_line,
    #state.target_indent,
  })

  print(
    string.format(
      "Paste replacement: replaced lines %s-%s",
      state.start_line,
      state.end_line
    )
  )

  paste_replace_state = nil
end

local function cancel_paste_replace()
  if paste_replace_state == nil then
    print("Paste replacement: no active replacement")
    return
  end

  close_scratch_buffer(paste_replace_state.scratch_buf)
  paste_replace_state = nil
  print("Paste replacement: cancelled")
end

vim.api.nvim_create_user_command("PasteReplaceStart", function(opts)
  start_paste_replace(opts.line1, opts.line2)
end, {
  range = true,
  desc = "Start paste replacement from selected range",
})

-- In visual mode, starting the command with ':' makes Neovim prepend the
-- selected range automatically. Do not write :'<,'> here, or the range is
-- duplicated and Neovim treats it as part of the command name.
vim.keymap.set("x", "<leader>pp", ":PasteReplaceStart<CR>", {
  desc = "Start paste replacement via scratch buffer",
})

vim.keymap.set("n", "<leader>pa", apply_paste_replace, {
  desc = "Apply paste replacement",
})

vim.keymap.set("n", "<leader>pc", cancel_paste_replace, {
  desc = "Cancel paste replacement",
})

-- -------------------------------------------------------------------
-- Pwrap selected text into ~/.prompt.xml
-- -------------------------------------------------------------------

local function cdata_escape(text)
  -- CDATA cannot contain ]]> directly.
  return text:gsub("]]>", "]]]]><![CDATA[>")
end

local function xml_attr_escape(text)
  text = tostring(text or "")
  text = text:gsub("&", "&amp;")
  text = text:gsub('"', "&quot;")
  text = text:gsub("<", "&lt;")
  text = text:gsub(">", "&gt;")
  return text
end

local function buffer_display_path()
  local path = vim.fn.expand("%:p")

  if path == "" then
    return "[No Name]"
  end

  local cwd = vim.fn.getcwd()

  if vim.startswith(path, cwd .. "/") then
    return string.sub(path, #cwd + 2)
  end

  return path
end

local function pwrap_lines(line1, line2)
  local lines = vim.fn.getline(line1, line2)

  if #lines == 0 then
    print("Pwrap: no lines selected")
    return
  end

  local prompt_file = vim.fn.expand("~/.prompt.xml")
  local file_path = buffer_display_path()
  local filetype = vim.bo.filetype

  if filetype == "" then
    filetype = "text"
  end

  local text = cdata_escape(table.concat(lines, "\n"))

  local block = {
    "",
    string.format(
      '<file path="%s" language="%s" lines="%s-%s" source="nvim-selection">',
      xml_attr_escape(file_path),
      xml_attr_escape(filetype),
      line1,
      line2
    ),
    "<![CDATA[",
  }

  -- writefile() writes one list item per line. If one list item contains
  -- embedded \n characters, they are not preserved as normal file line breaks.
  -- So split the selected text back into real output lines before appending.
  vim.list_extend(block, vim.split(text, "\n", { plain = true }))

  vim.list_extend(block, {
    "]]>",
    "</file>",
    "",
  })

  vim.fn.writefile(block, prompt_file, "a")

  print(
    string.format(
      "Pwrap: added %s lines from %s:%s-%s to ~/.prompt.xml",
      #lines,
      file_path,
      line1,
      line2
    )
  )
end

vim.api.nvim_create_user_command("Pwrap", function(opts)
  pwrap_lines(opts.line1, opts.line2)
end, {
  range = true,
  desc = "Append selected lines to ~/.prompt.xml",
})

vim.keymap.set("x", "<leader>pw", ":Pwrap<CR>", {
  desc = "Pwrap visual selection",
})

local function set_transparent_dark()
  vim.o.background = "dark"

  local groups = {
    "Normal",
    "NormalNC",
    "SignColumn",
    "EndOfBuffer",
    "LineNr",
    "StatusLine",
    "StatusLineNC",
  }

  for _, group in ipairs(groups) do
    vim.api.nvim_set_hl(0, group, { bg = "NONE" })
  end

  vim.fn.writefile({ "dark" }, theme_state_file)

  print("Theme mode: transparent dark")
end

-- -------------------------------------------------------------------
-- Search highlight without jumping
-- -------------------------------------------------------------------

local function very_nomagic_pattern(text)
  -- \V = very nomagic, so most characters are treated literally.
  -- Escape backslashes because they still matter.
  return "\\V" .. text:gsub("\\", "\\\\")
end

local function clear_search_highlight()
  vim.cmd("nohlsearch")
  vim.cmd("redraw")
  print("Search highlight cleared")
end

local function highlight_search_text(text)
  if text == nil or text == "" then
    clear_search_highlight()
    return
  end

  vim.fn.setreg("/", very_nomagic_pattern(text))
  vim.opt.hlsearch = true
  vim.cmd("redraw")
  print("Highlighted: " .. text)
end

local function highlight_search_prompt()
  local text = vim.fn.input("Highlight search: ")
  highlight_search_text(text)
end

local function get_visual_selection_text()
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")

  local start_line = start_pos[2]
  local start_col = start_pos[3]
  local end_line = end_pos[2]
  local end_col = end_pos[3]

  local lines = vim.fn.getline(start_line, end_line)

  if #lines == 0 then
    return ""
  end

  if #lines == 1 then
    lines[1] = string.sub(lines[1], start_col, end_col)
  else
    lines[1] = string.sub(lines[1], start_col)
    lines[#lines] = string.sub(lines[#lines], 1, end_col)
  end

  return table.concat(lines, "\n")
end

vim.keymap.set("n", "<leader>/", highlight_search_prompt, {
  desc = "Highlight search without jumping",
})

vim.keymap.set("n", "<leader>nh", clear_search_highlight, {
  desc = "Clear search highlight",
})

vim.keymap.set("x", "<leader>/", function()
  local text = get_visual_selection_text()
  highlight_search_text(text)
end, {
  desc = "Highlight selected text without jumping",
})

local function set_safe_light()
  vim.o.background = "light"

  vim.api.nvim_set_hl(0, "Normal",       { fg = "#1f2328", bg = "#ffffff" })
  vim.api.nvim_set_hl(0, "NormalNC",     { fg = "#1f2328", bg = "#ffffff" })
  vim.api.nvim_set_hl(0, "SignColumn",   { fg = "#57606a", bg = "#ffffff" })
  vim.api.nvim_set_hl(0, "EndOfBuffer",  { fg = "#ffffff", bg = "#ffffff" })
  vim.api.nvim_set_hl(0, "LineNr",       { fg = "#6e7781", bg = "#ffffff" })
  vim.api.nvim_set_hl(0, "StatusLine",   { fg = "#ffffff", bg = "#57606a" })
  vim.api.nvim_set_hl(0, "StatusLineNC", { fg = "#57606a", bg = "#eaeef2" })

  vim.fn.writefile({ "light" }, theme_state_file)

  print("Theme mode: safe light")
end

local function toggle_safe_light()
  local current = "dark"

  if vim.fn.filereadable(theme_state_file) == 1 then
    current = vim.fn.readfile(theme_state_file)[1]
  end

  if current == "dark" then
    set_safe_light()
  else
    set_transparent_dark()
  end
end

vim.keymap.set(
  "n",
  "<leader>tl",
  toggle_safe_light,
  { desc = "Toggle safe light mode" }
)

-- Restore saved theme mode on startup
if vim.fn.filereadable(theme_state_file) == 1 then
  local saved = vim.fn.readfile(theme_state_file)[1]

  if saved == "light" then
    set_safe_light()
  else
    set_transparent_dark()
  end
else
  set_transparent_dark()
end

local function is_code_window(win)
  local buf = vim.api.nvim_win_get_buf(win)
  local ft = vim.bo[buf].filetype
  local bt = vim.bo[buf].buftype

  if ft == "NvimTree" then
    return false
  end

  if bt == "terminal" then
    return false
  end

  return true
end

local function sorted_windows()
  local wins = vim.api.nvim_tabpage_list_wins(0)

  table.sort(wins, function(a, b)
    local ar, ac = unpack(vim.fn.win_screenpos(vim.api.nvim_win_get_number(a)))
    local br, bc = unpack(vim.fn.win_screenpos(vim.api.nvim_win_get_number(b)))

    if ac == bc then
      return ar < br
    end

    return ac < bc
  end)

  return wins
end

local function focus_code_pane(n)
  local code_wins = {}

  for _, win in ipairs(sorted_windows()) do
    if is_code_window(win) then
      table.insert(code_wins, win)
    end
  end

  local target = code_wins[n]

  if target then
    vim.api.nvim_set_current_win(target)
  else
    print("Code pane " .. n .. " not found")
  end
end

vim.keymap.set("n", "<leader>A", function()
  focus_code_pane(1)
end, { desc = "Focus first code pane" })

vim.keymap.set("n", "<leader>B", function()
  focus_code_pane(2)
end, { desc = "Focus second code pane" })

vim.keymap.set("n", "<leader>F", "<cmd>IronFocus<CR>", { desc = "Focus Iron console" })
                        
                        
local function python_cmd()
  local venv = os.getenv("VIRTUAL_ENV")
  if venv then
    local ipy = venv .. "\\Scripts\\ipython.exe"
    if vim.fn.executable(ipy) == 1 then
      return { ipy }
    end
    local py = venv .. "\\Scripts\\python.exe"
    if vim.fn.executable(py) == 1 then
      return { py }
    end
  end

  if vim.fn.executable("ipython") == 1 then
    return { "ipython" }
  end

  return { "python" }
end

local r_cmd = [[/usr/local/bin/R]]

local function toggle_r()
  local r453 = [[/usr/local/bin/R]]
  local r443 = [[/bin/R]]

  if r_cmd == r453 then
    r_cmd = r443
    print("R set to 4.4.3")
  else
    r_cmd = r453
    print("R set to 4.5.3")
  end
end

iron.setup({
  config = {
    scratch_repl = true,
    repl_definition = {
      python = {
        command = python_cmd(),
        format = require('iron.fts.common').bracketed_paste,
      },
      r = {
        command = function()
          return { r_cmd }
        end,
      },
    },
    repl_filetype = function(bufnr, ft)
      return ft
    end,
    -- repl_open_cmd = 'leftabove 40vsplit',
    -- repl_open_cmd = 'leftabove 60vsplit',
    -- repl_open_cmd = 'rightbelow 40vsplit',
    repl_open_cmd = {
          view.split.belowright(15),
            view.split.vertical.rightbelow("40%"),
    },
  },
    keymaps = {
      toggle_repl = "<leader>rr",
      toggle_repl_with_cmd_1 = "<leader>rr",
      toggle_repl_with_cmd_2 = "<leader>rv",

      restart_repl = "<leader>rR",
      send_motion = "<leader>sc",
      visual_send = "<leader>sc",
      send_file = "<leader>sf",
      send_line = "<leader>sl",
      send_paragraph = "<leader>sp",
      send_until_cursor = "<leader>su",
      send_code_block = "<leader>sb",
      send_code_block_and_move = "<leader>sn",
    },
})

vim.keymap.set('n', '<leader>rt', toggle_r)		
vim.keymap.set('n', '<leader>rf', '<cmd>IronFocus<CR>')
vim.keymap.set('n', '<leader>rh', '<cmd>IronHide<CR>')

cmp.setup({
  snippet = {
    expand = function(args)
      luasnip.lsp_expand(args.body)
    end,
  },

  completion = {
    completeopt = 'menu,menuone,noinsert,noselect',
    autocomplete = false,
  },

  window = {
    completion = cmp.config.window.bordered(),
    documentation = cmp.config.window.bordered(),
  },

  experimental = {
    ghost_text = false,
  },

  formatting = {
    fields = { 'abbr', 'kind', 'menu' },
    format = function(entry, vim_item)
      local menu = {
        nvim_lsp = '[LSP]',
        luasnip = '[Snip]',
      }
      vim_item.menu = menu[entry.source.name] or ''
      return vim_item
    end,
  },

  mapping = {
    ['<C-Space>'] = cmp.mapping.complete(),
    ['<C-e>'] = cmp.mapping.abort(),
    ['<CR>'] = cmp.mapping.confirm({ select = false }),

    ['<Tab>'] = cmp.mapping(function(fallback)
      if cmp.visible() then
        cmp.select_next_item({ behavior = cmp.SelectBehavior.Select })
        return
      end

      local col = vim.fn.col('.') - 1
      local line = vim.fn.getline('.')
      local prev = col > 0 and line:sub(col, col) or ''

      if prev == '.' then
        cmp.complete()
      elseif luasnip.expand_or_jumpable() then
        luasnip.expand_or_jump()
      else
        fallback()
      end
    end, { 'i', 's' }),

    ['<S-Tab>'] = cmp.mapping(function(fallback)
      if cmp.visible() then
        cmp.select_prev_item({ behavior = cmp.SelectBehavior.Select })
      elseif luasnip.jumpable(-1) then
        luasnip.jump(-1)
      else
        fallback()
      end
    end, { 'i', 's' }),

    ['<C-n>'] = cmp.mapping.select_next_item({ behavior = cmp.SelectBehavior.Select }),
    ['<C-p>'] = cmp.mapping.select_prev_item({ behavior = cmp.SelectBehavior.Select }),
    ['<C-f>'] = cmp.mapping.scroll_docs(4),
    ['<C-b>'] = cmp.mapping.scroll_docs(-4),
  },

  sources = {
    { name = 'nvim_lsp' },
    { name = 'luasnip' },
  },
})

local capabilities = require('cmp_nvim_lsp').default_capabilities()

vim.lsp.config('pyright', {
  capabilities = capabilities,
})

vim.lsp.enable('pyright')

vim.api.nvim_create_autocmd('LspAttach', {
  callback = function(args)
    local opts = { buffer = args.buf, silent = true }
    vim.keymap.set('n', 'gd', vim.lsp.buf.definition, opts)
    vim.keymap.set('n', 'gr', vim.lsp.buf.references, opts)
    vim.keymap.set('n', 'K', vim.lsp.buf.hover, opts)
    vim.keymap.set('n', '<leader>rn', vim.lsp.buf.rename, opts)
    vim.keymap.set('n', '<leader>ca', vim.lsp.buf.code_action, opts)
  end,
})

vim.diagnostic.config({
  virtual_text = true,
  float = {
    border = 'rounded',
  },
  signs = {
    text = {
      [vim.diagnostic.severity.ERROR] = 'E',
      [vim.diagnostic.severity.WARN] = 'W',
      [vim.diagnostic.severity.HINT] = 'H',
      [vim.diagnostic.severity.INFO] = 'I',
    },
  },
})

vim.keymap.set('n', ']d', vim.diagnostic.goto_next)
vim.keymap.set('n', '[d', vim.diagnostic.goto_prev)

require('conform').setup({
  formatters_by_ft = {
    python = { 'black' },
  },
  format_on_save = {
    timeout_ms = 20000,
    lsp_fallback = true,
  },
})

local lint = require('lint')
lint.linters_by_ft = {
  python = { 'ruff' },
}

vim.api.nvim_create_autocmd({ 'BufWritePost', 'BufEnter', 'InsertLeave' }, {
  callback = function()
    require('lint').try_lint()
  end,
})

require('gitsigns').setup({
  current_line_blame = true,
  on_attach = function(bufnr)
    local gs = package.loaded.gitsigns
    local function map(mode, lhs, rhs)
      vim.keymap.set(mode, lhs, rhs, { buffer = bufnr })
    end

    map('n', ']h', gs.next_hunk)
    map('n', '[h', gs.prev_hunk)
    map('n', '<leader>hp', gs.preview_hunk)
    map('n', '<leader>hs', gs.stage_hunk)
    map('n', '<leader>hr', gs.reset_hunk)
    map('n', '<leader>hb', gs.blame_line)
  end,
})

require('nvim-tree').setup({
  update_focused_file = {
    enable = true,
    update_root = false,
  },
  view = {
    width = 35,
  },
  renderer = {
    group_empty = true,
  },
})

require('telescope').setup({})

require('lualine').setup({
  options = {
    theme = 'auto',
    globalstatus = true,
    section_separators = '',
    component_separators = '|',
  },
  sections = {
    lualine_a = { 'mode' },
    lualine_b = { 'branch', 'diff', 'diagnostics' },
    lualine_c = {
      {
        'filename',
        path = 1,
      },
    },
    lualine_x = {
      {
        function()
          local clients = vim.lsp.get_clients({ bufnr = 0 })
          if #clients == 0 then
            return ''
          end
          return clients[1].name
        end,
      },
      'encoding',
      'filetype',
    },
    lualine_y = { 'progress' },
    lualine_z = { 'location' },
  },
})

local venv_python = os.getenv('VIRTUAL_ENV') and (os.getenv('VIRTUAL_ENV') .. '/bin/python') or 'python'
require('dap-python').setup(venv_python)

local dap = require('dap')
local dapui = require('dapui')

dapui.setup()

dap.listeners.before.attach.dapui_config = function()
  dapui.open()
end
dap.listeners.before.launch.dapui_config = function()
  dapui.open()
end
dap.listeners.before.event_terminated.dapui_config = function()
  dapui.close()
end
dap.listeners.before.event_exited.dapui_config = function()
  dapui.close()
end

vim.keymap.set('n', '<F5>', dap.continue)
vim.keymap.set('n', '<F10>', dap.step_over)
vim.keymap.set('n', '<F11>', dap.step_into)
vim.keymap.set('n', '<F12>', dap.step_out)
vim.keymap.set('n', '<leader>du', dapui.toggle)
vim.keymap.set('n', '<leader>dr', dap.repl.open)

vim.keymap.set('n', '<leader>b', dap.toggle_breakpoint)
vim.keymap.set('n', '<leader>bc', function()
  dap.set_breakpoint(vim.fn.input('Breakpoint condition: '))
end)

EOF
