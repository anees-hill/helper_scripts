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
    r_cmd = r453
    print("R set to 4.5.3")
  else
    r_cmd = r443
    print("R set to 4.4.3")
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
