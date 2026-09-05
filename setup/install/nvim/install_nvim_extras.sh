#!/bin/bash
#
# install_nvim_extras.sh — layer a full IDE-grade setup on top of kickstart.nvim.
#
# WHY A SECOND SCRIPT
# -------------------
# install_nvim.sh installs Neovim itself and a PRISTINE kickstart.nvim checkout,
# so `git pull` in ~/.config/nvim keeps working forever. This script adds
# everything kickstart deliberately leaves out, without touching that checkout:
# Neovim sources plugin/*.lua from the config directory automatically, after
# init.lua, so the layer lives in files kickstart does not own and the two never
# fight over the same lines.
#
# WHAT IT ADDS  (the list from itsjfx's "5 weeks of Neovim" write-up)
#   buffer manager        barbar.nvim
#   directory managers    oil.nvim (edit a directory like a buffer) + neo-tree (sidebar)
#   colorizer             nvim-colorizer.lua — paints #rrggbb in its own colour
#   session manager       vim-obsession + a `vw` shell command, VS Code "workspaces"
#   rainbow parentheses   rainbow-delimiters.nvim
#   indentation guides    indent-blankline.nvim
#   movement              leap.nvim, quick-scope, mini.move
#   git                   vim-fugitive, vim-flog, vim-gh-line (+ kickstart's gitsigns)
#   quality of life       bullets.vim, mini.cursorword, committia.vim, vim-easy-align,
#                         nvim-treesitter-context, rainbow_csv, vim-repeat
#   startup               the file tree and a start page, so the editor LOOKS
#                         configured instead of showing the stock splash screen
#
# AND THE REST OF THE VS CODE FEATURE LIST (50-b2b-markdown, 60-b2b-ide)
#   markdown, in-buffer   render-markdown.nvim — headings, bullets, tables and
#                         checkboxes drawn in the buffer you are still editing
#   markdown, in browser  markdown-preview.nvim — the live rendered page, with
#                         mermaid diagrams and maths. Headless-aware: this VM has
#                         no browser, so it PRINTS the URL and you open it from
#                         the host over an SSH tunnel (see :B2BMarkdown).
#   linting               nvim-lint, driven by shellcheck / markdownlint
#   debugger              nvim-dap + dap-ui, on gdb's own DAP interpreter for
#                         C/C++ and debugpy for Python — no Mason download
#   test runner           neotest (+ the python adapter)
#   terminal              toggleterm.nvim, which also hosts lazygit
#   git UI                lazygit (Debian package) in a floating terminal
#   symbol outline        aerial.nvim
#   breadcrumbs           nvim-navic, in the winbar
#   project management    project.nvim + its telescope picker
#   REST client           kulala.nvim (run .http files from the buffer)
#   SQL client            vim-dadbod + dadbod-ui + dadbod-completion — the VM
#                         already runs MariaDB for WordPress, so this is wired
#                         to it out of the box
#   AI assistant          codecompanion.nvim, only when a key/endpoint exists
#
# Autocomplete, go-to-definition, find-references, inline diagnostics, rename
# and formatting are NOT here on purpose: kickstart already provides all six
# (blink.cmp, vim.lsp and conform.nvim). A tab bar is not here either — barbar,
# above, is the same feature as bufferline.
#
# A NOTE ON MEMORY. This VM is sized at 2 GB and already runs Docker, MariaDB
# and lighttpd. One Neovim with this plugin set and an LSP server is
# comfortable; several at once (say, a few tmux windows each with its own
# language server) will push the box into swap. If you work that way, give the
# VM more RAM rather than trimming the config.
#   fuzzy finding         fzf + fzf.vim beside kickstart's telescope
#   keybindings           the VS Code muscle memory: C-p, C-S-f, C-/, C-b, C-s
#
# TWO DELIBERATE SUBSTITUTIONS, both because the post's choice is now dead:
#   * rainbow parentheses — the post uses lincheney's fork of nvim-ts-rainbow.
#     Both that fork and its upstream were ARCHIVED in 2023 and target the old
#     nvim-treesitter API; kickstart tracks nvim-treesitter's `main` branch,
#     where they do not load at all. rainbow-delimiters.nvim is the maintained
#     successor by the same community and does the same job.
#   * bullets.vim — dkarter/bullets.vim now redirects to bullets-vim/bullets.vim.
#
# Plugins are installed with `vim.pack`, Neovim 0.12's built-in plugin manager —
# the same mechanism kickstart itself uses, so there is no second plugin manager
# in the config and `:checkhealth vim.pack` covers everything.
#
# USAGE
#   sudo ./install_nvim_extras.sh                     # default: user dlesieur
#   sudo NVIM_USERS="dlesieur root" ./install_nvim_extras.sh
#   sudo NVIM_BOOTSTRAP=0 ./install_nvim_extras.sh    # write config, skip the download

set -u

# This script runs from three places with three different environments: a login
# shell over SSH, `sudo env ... bash` from the host provisioner, and @reboot
# cron on the very first boot. Only the first of those is guaranteed to have
# /usr/local/bin on PATH, and that is where nvim, tree-sitter and the npm
# globals all live -- so pin it rather than inherit it.
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
# The npm prefix is moved to /opt by install_global_scope.sh, and npm's own
# bin directory is NOT on the default PATH. Without this line a package this
# script installs itself (tree-sitter, claude) is invisible to the very next
# `command -v` that checks for it -- installed, working, and reported missing.
# Ask npm where it actually is rather than hardcoding the location.
if command -v npm >/dev/null 2>&1; then
	_npm_prefix=$(npm config get prefix --global 2>/dev/null)
	case "$_npm_prefix" in
		/*) [ -d "${_npm_prefix}/bin" ] && PATH="${_npm_prefix}/bin:$PATH" ;;
	esac
	unset _npm_prefix
fi
export PATH

NVIM_BIN="${NVIM_BIN:-/usr/local/bin/nvim}"

NVIM_USERS="${NVIM_USERS:-dlesieur}"
NVIM_BOOTSTRAP="${NVIM_BOOTSTRAP:-1}"
NVIM_BOOTSTRAP_TIMEOUT="${NVIM_BOOTSTRAP_TIMEOUT:-1200}"
NVIM_SESSION_DIR_NAME="${NVIM_SESSION_DIR_NAME:-.nvim-sessions}"
# Must match install_nvim.sh — that script builds the venv (for pynvim), this
# one adds debugpy to it and points nvim-dap at the same interpreter.
NVIM_PYTHON_VENV="${NVIM_PYTHON_VENV:-/opt/nvim-venv}"
# The port markdown-preview.nvim's server listens on. Fixed rather than random
# so the SSH tunnel you set up once keeps working; see write_markdown_lua.
#
# 8420 and not the obvious 8080/8090: this VM already serves lighttpd on 80/443,
# the Inception stack on 8080/8081/8082 and its static site on 8090 (see
# setup/host/deploy_inception.sh). Picking one of those gives you a preview that
# dies with "EADDRINUSE" only on the machines where the other stack is running —
# which is the worst kind of bug to find later. Override with NVIM_MKDP_PORT.
NVIM_MKDP_PORT="${NVIM_MKDP_PORT:-8420}"

log()  { printf '[nvim-extras] %s\n' "$*"; }
warn() { printf '[nvim-extras] WARN: %s\n' "$*" >&2; }
die()  { printf '[nvim-extras] ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root (use sudo)"
[ -x "$NVIM_BIN" ] || NVIM_BIN=$(command -v nvim 2>/dev/null || true)
[ -n "$NVIM_BIN" ] && [ -x "$NVIM_BIN" ] \
	|| die "nvim is not installed — run install_nvim.sh first"

# ── Extra system packages these plugins shell out to ────────────────────────
#   fzf       fzf.vim drives the `fzf` binary; the plugin is only the glue
#   bat       fzf.vim's file preview uses it when present (falls back to cat)
#   git       vim-fugitive / vim-flog / gitsigns
#   xdg-utils vim-gh-line opens URLs (harmless on a headless box; it just prints)
#   lazygit   the git UI, run inside toggleterm. Debian trixie packages 0.50.0,
#             so there is no reason to download a release tarball for it.
#   gdb       nvim-dap's debug adapter for C/C++. gdb has spoken DAP natively
#             since 14 (`gdb -i dap`) and trixie ships 16.3, so the debugger
#             needs no Mason package, no codelldb download and no rust toolchain.
#   sh linting  the shellcheck binary, which nvim-lint drives for sh/bash —
#             which is most of THIS repo. (Naming it at the start of a comment
#             line would be read as a `# shellcheck` directive, hence the wrap.)
#   mariadb-client  vim-dadbod shells out to `mysql` to talk to the WordPress DB
install_deps() {
	log "installing fzf, bat, lazygit, gdb and friends"
	export DEBIAN_FRONTEND=noninteractive
	apt-get update -qq 2>/dev/null || warn "apt-get update failed — using the current index"

	# lazygit is only in trixie and newer. Install the batch first, and let a
	# failure fall through to the per-package loop rather than taking fzf and
	# gdb down with it on an older release.
	local pkgs="fzf bat git ripgrep xdg-utils lazygit gdb shellcheck mariadb-client"
	# $pkgs is deliberately unquoted: it is a space-separated package list and
	# the word splitting is the point. Quoting it asks apt for one package with
	# spaces in its name.
	# shellcheck disable=SC2086
	if ! apt-get install -y -qq -o Dpkg::Options::=--force-confdef \
		-o Dpkg::Options::=--force-confold $pkgs 2>/dev/null; then
		warn "batch install failed — retrying package by package"
		local p
		for p in $pkgs; do
			apt-get install -y -qq "$p" 2>/dev/null || warn "could not install $p"
		done
	fi

	# Debian installs bat as `batcat` (name clash with the `bacula` bat tool).
	# fzf.vim's preview looks for `bat`, so give it one.
	if command -v batcat >/dev/null 2>&1 && ! command -v bat >/dev/null 2>&1; then
		ln -sf "$(command -v batcat)" /usr/local/bin/bat
		log "linked batcat -> /usr/local/bin/bat"
	fi

	# No mariadb->mysql symlink here, unlike fd and bat above, and that is
	# checked rather than assumed: vim-dadbod hardcodes the binary name
	# (autoload/db/adapter/mysql.vim opens `let command = ['mysql']`), but
	# mariadb-client Depends on mariadb-client-core, and it is THAT package
	# which ships /usr/bin/mysql as a symlink to mariadb. Verified on the VM:
	#     dpkg -S /usr/bin/mysql  ->  mariadb-client-core
	# So installing mariadb-client always brings `mysql` with it.

	# markdownlint is nvim-lint's markdown linter and there is no Debian package
	# for it. Installed globally with npm, beside the node provider and the
	# tree-sitter CLI that install_nvim.sh already puts there.
	if command -v npm >/dev/null 2>&1; then
		if ! command -v markdownlint-cli2 >/dev/null 2>&1; then
			log "installing markdownlint-cli2 (nvim-lint's markdown linter)"
			npm install -g markdownlint-cli2 >/dev/null 2>&1 \
				|| warn "npm install -g markdownlint-cli2 failed — markdown linting will be off"
		fi
	else
		warn "npm not available — skipping markdownlint-cli2"
	fi

	# debugpy for nvim-dap's Python adapter, into the same venv install_nvim.sh
	# built for pynvim. Debian's python3 is PEP 668 externally-managed, so this
	# is the only place it can go without --break-system-packages.
	if [ -x "${NVIM_PYTHON_VENV}/bin/pip" ]; then
		log "installing debugpy into ${NVIM_PYTHON_VENV} (nvim-dap's python adapter)"
		"${NVIM_PYTHON_VENV}/bin/pip" install --quiet debugpy >/dev/null 2>&1 \
			|| warn "pip install debugpy failed — python debugging will be off"
		chmod -R a+rX "$NVIM_PYTHON_VENV" 2>/dev/null || true
	else
		warn "no venv at ${NVIM_PYTHON_VENV} — skipping debugpy (run install_nvim.sh first)"
	fi

	apt-get clean 2>/dev/null || true

	# Report what actually landed, because "the apt line ran" is not the same
	# thing as "the binary is on PATH" -- and every one of these is a feature
	# that silently does nothing when its binary is missing.
	local tool
	for tool in fzf lazygit gdb shellcheck markdownlint-cli2 mysql; do
		if command -v "$tool" >/dev/null 2>&1; then
			log "  ok   ${tool}"
		else
			warn "  MISS ${tool} — the feature that uses it will be inactive"
		fi
	done
}

# ── The shared plugin-install helper ────────────────────────────────────────
# Extracted from 10-b2b-plugins.lua when the markdown and IDE layers were added:
# all three files need the same install-and-reconcile logic and the same failure
# reporting, and three copies of it would be three things to fix separately.
#
# It loads first (05 sorts before 10) and publishes _G.B2B, so every later file
# is `B2B.add { ... }` plus `B2B.try(...)` around its setup calls.
write_pack_lua() {
	local cfg="$1"
	mkdir -p "${cfg}/plugin"
	cat > "${cfg}/plugin/05-b2b-pack.lua" <<'LUAEOF'
-- 05-b2b-pack.lua — the install helper the rest of the born2root layer uses.
--
-- Written by setup/install/nvim/install_nvim_extras.sh. Files in plugin/ are
-- sourced in name order after init.lua, so this one runs before 10/50/60 and
-- leaves _G.B2B behind for them.
--
-- Everything is installed with `vim.pack`, Neovim 0.12's built-in plugin
-- manager -- the same one kickstart itself uses, so there is exactly one
-- plugin manager in this config and `:checkhealth vim.pack` sees all of it.
--
-- `:B2BExtras` reports what loaded and what did not.

if vim.pack == nil then
  vim.notify('b2b: vim.pack is missing — Neovim 0.12+ is required', vim.log.levels.ERROR)
  return
end

local B2B = {
  specs = {},     -- every spec any layer asked for, in order
  problems = {},  -- '<label>: <error>' for anything that failed
}
_G.B2B = B2B

B2B.pack_root = vim.fn.stdpath 'data' .. '/site/pack/core/opt/'

function B2B.gh(repo) return 'https://github.com/' .. repo end

local function spec_name(spec) return spec.name or spec.src:match '[^/]+$' end
B2B.spec_name = spec_name

-- Run a setup step, recording the failure instead of letting it abort the file:
-- on a headless VM one plugin that failed to clone must not take the other
-- twenty with it. :B2BExtras prints whatever ended up in B2B.problems.
function B2B.try(label, fn)
  local ok, err = pcall(fn)
  if not ok then table.insert(B2B.problems, ('%s: %s'):format(label, tostring(err))) end
  return ok
end

-- 'ok' | 'MISS' | 'EMPTY'. EMPTY is a real state, not paranoia: a repo whose
-- default branch was emptied upstream still clones perfectly, so "the directory
-- is there" is not evidence a plugin is installed. See the leap.nvim note below.
function B2B.status(name)
  local dir = B2B.pack_root .. name
  if vim.fn.isdirectory(dir) == 0 then return 'MISS' end
  if vim.fn.isdirectory(dir .. '/lua') == 1
    or vim.fn.isdirectory(dir .. '/plugin') == 1
    or vim.fn.isdirectory(dir .. '/autoload') == 1
  then
    return 'ok'
  end
  return 'EMPTY'
end

-- Guard a config block that would otherwise throw a confusing error when the
-- download failed: `if B2B.have 'aerial.nvim' then ... end`.
function B2B.have(name) return B2B.status(name) == 'ok' end

-- ── Reconcile checkouts whose upstream moved ───────────────────────────────
-- vim.pack keys a plugin by NAME and keeps its own registry of where that name
-- was installed from. Once leap.nvim is recorded as coming from GitHub, adding
-- it again with a different `src` silently reuses the RECORDED url -- editing
-- the URL in the spec, on its own, would never take effect on a machine that
-- already installed the old one. Verified: with src set to the Codeberg URL,
-- vim.pack still announced "leap.nvim from https://github.com/ggandor/leap.nvim".
--
-- Deleting the directory is not enough either, because the registry entry
-- outlives it: the next add re-clones from the old URL. `vim.pack.del` is the
-- operation that actually forgets the plugin, so that is what is used here.
local function needs_reinstall(spec)
  local dir = B2B.pack_root .. spec_name(spec)
  if vim.fn.isdirectory(dir) == 0 then return false end
  if B2B.status(spec_name(spec)) == 'EMPTY' then return true, 'the checkout has no code in it' end

  local origin = vim.fn.systemlist { 'git', '-C', dir, 'remote', 'get-url', 'origin' }
  origin = (vim.v.shell_error == 0 and origin[1]) and vim.trim(origin[1]) or nil
  -- A trailing .git is the same remote; do not churn over it.
  if origin and origin:gsub('%.git$', '') ~= spec.src:gsub('%.git$', '') then
    return true, 'upstream moved to ' .. spec.src
  end
  return false
end

-- Install a batch. One call is much faster (vim.pack parallelises the clones),
-- but a single bad spec fails the whole batch -- so try the batch, and only on
-- failure fall back to one-at-a-time, which names the broken one and still
-- installs the rest.
function B2B.add(specs)
  for _, spec in ipairs(specs) do
    table.insert(B2B.specs, spec)
    local ok, stale, why = pcall(needs_reinstall, spec)
    if ok and stale then
      local name = spec_name(spec)
      vim.notify(('b2b: reinstalling %s (%s)'):format(name, why), vim.log.levels.INFO)
      -- del first (forgets the registry entry), then remove any directory it
      -- left behind, so the add below starts from nothing.
      pcall(vim.pack.del, { name })
      if vim.fn.isdirectory(B2B.pack_root .. name) == 1 then
        vim.fn.delete(B2B.pack_root .. name, 'rf')
      end
    end
  end

  if not pcall(vim.pack.add, specs) then
    for _, spec in ipairs(specs) do
      B2B.try('install ' .. spec_name(spec), function() vim.pack.add { spec } end)
    end
  end
end

-- ── :B2BExtras — what actually loaded ──────────────────────────────────────
vim.api.nvim_create_user_command('B2BExtras', function()
  local lines = { 'born2root Neovim extras', '' }
  for _, spec in ipairs(B2B.specs) do
    local status = B2B.status(spec_name(spec))
    lines[#lines + 1] = ('  %-4s %s'):format(status == 'ok' and 'ok' or status, spec_name(spec))
  end
  if #B2B.problems > 0 then
    lines[#lines + 1] = ''
    lines[#lines + 1] = 'problems:'
    for _, p in ipairs(B2B.problems) do lines[#lines + 1] = '  ' .. p end
  else
    lines[#lines + 1] = ''
    lines[#lines + 1] = 'no setup errors'
  end
  vim.notify(table.concat(lines, '\n'), #B2B.problems > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
end, { desc = 'Report which born2root Neovim extras loaded' })

-- Surface breakage once at startup rather than leaving it silent. Scheduled so
-- it runs after EVERY plugin/*.lua file has been sourced -- 10, 50 and 60 all
-- append to B2B.problems, and a notify at the bottom of this file would report
-- on an empty list.
vim.schedule(function()
  if #B2B.problems > 0 then
    vim.notify(('b2b: %d plugin problem(s) — run :B2BExtras'):format(#B2B.problems), vim.log.levels.WARN)
  end
end)
LUAEOF
	chmod 644 "${cfg}/plugin/05-b2b-pack.lua"
}

# ── The plugin layer ────────────────────────────────────────────────────────
write_plugins_lua() {
	local cfg="$1"
	mkdir -p "${cfg}/plugin"
	cat > "${cfg}/plugin/10-b2b-plugins.lua" <<'LUAEOF'
-- 10-b2b-plugins.lua — everything kickstart.nvim leaves out.
--
-- Written by setup/install/nvim/install_nvim_extras.sh. It lives in plugin/,
-- which Neovim sources automatically AFTER init.lua, so the kickstart checkout
-- next to it stays pristine and `git pull` in ~/.config/nvim keeps working.
--
-- Plugins are declared through _G.B2B (see 05-b2b-pack.lua), which wraps
-- `vim.pack`, Neovim 0.12's built-in manager — the same one kickstart uses, so
-- there is exactly one plugin manager in this config and `:checkhealth vim.pack`
-- sees all of it.
--
-- `:B2BExtras` reports what loaded and what did not.

local B2B = _G.B2B
if B2B == nil then
  vim.notify('b2b: 05-b2b-pack.lua did not load — extras are off', vim.log.levels.ERROR)
  return
end
local gh, try = B2B.gh, B2B.try

-- ── Settings that must be in place BEFORE the plugins load ─────────────────

-- Both oil.nvim and neo-tree replace netrw as the directory browser. Leaving
-- netrw enabled means whichever loads second fights it for the buffer.
vim.g.loaded_netrw = 1
vim.g.loaded_netrwPlugin = 1

-- barbar sets itself up on load unless told not to; we want to pass options.
vim.g.barbar_auto_setup = false

-- quick-scope only highlights while a jump key is actually pending, which is
-- the whole point — permanent highlighting is noise.
vim.g.qs_highlight_on_keys = { 'f', 'F', 't', 'T' }

-- vim-gh-line binds <leader>gh by default; keep the binding but declare it
-- here so it is visible next to every other mapping rather than a surprise.
vim.g.gh_line_map_default = 0
vim.g.gh_line_blame_map_default = 0
vim.g.gh_line_map = '<leader>gho'
vim.g.gh_line_blame_map = '<leader>ghb'

-- ── Declare the plugins ────────────────────────────────────────────────────
local specs = {
  -- shared dependencies (kickstart already provides plenary.nvim and mini.nvim)
  { src = gh 'nvim-tree/nvim-web-devicons' },
  { src = gh 'MunifTanjim/nui.nvim' },

  -- buffer manager — the VS Code tab bar
  { src = gh 'romgrk/barbar.nvim' },

  -- directory managers: oil edits a directory as a buffer, neo-tree is the sidebar
  { src = gh 'stevearc/oil.nvim' },
  { src = gh 'nvim-neo-tree/neo-tree.nvim' },

  -- colorizer: paints #rrggbb / rgb() in the colour it names.
  -- catgoose's fork, not norcalli's: the original has been unmaintained since
  -- 2020 and does not handle Neovim's current highlight API.
  { src = gh 'catgoose/nvim-colorizer.lua' },

  -- session manager — VS Code workspaces, via tpope's mksession wrapper
  { src = gh 'tpope/vim-obsession' },

  -- rainbow parentheses (see the substitution note in the installer header)
  { src = gh 'HiPhish/rainbow-delimiters.nvim' },

  -- indentation guides
  { src = gh 'lukas-reineke/indent-blankline.nvim' },

  -- movement.
  -- leap is NOT on GitHub any more: the author moved it to Codeberg and wiped
  -- the GitHub default branch (its last commit is literally "nuke it from
  -- orbit"), leaving a repo that still clones fine and contains only a README.
  -- Pulling from github.com/ggandor/leap.nvim therefore succeeds and installs
  -- nothing, which is exactly the failure mode this comment exists to prevent
  -- someone "fixing" back.
  { src = 'https://codeberg.org/andyg/leap.nvim' },
  { src = gh 'unblevable/quick-scope' },

  -- git, on top of kickstart's gitsigns
  { src = gh 'tpope/vim-fugitive' },
  { src = gh 'rbong/vim-flog' },
  { src = gh 'ruanyl/vim-gh-line' },

  -- fuzzy finding, beside kickstart's telescope
  { src = gh 'junegunn/fzf' },
  { src = gh 'junegunn/fzf.vim' },

  -- quality of life
  { src = gh 'bullets-vim/bullets.vim' },
  { src = gh 'rhysd/committia.vim' },
  { src = gh 'junegunn/vim-easy-align' },
  { src = gh 'nvim-treesitter/nvim-treesitter-context' },
  { src = gh 'mechatroner/rainbow_csv' },
  { src = gh 'tpope/vim-repeat' },
}

-- B2B.add reconciles checkouts whose upstream moved (leap.nvim above is exactly
-- that case) before installing. See 05-b2b-pack.lua for why that is necessary.
B2B.add(specs)

-- ── Configure them ─────────────────────────────────────────────────────────
-- kickstart's `have_nerd_font` decides whether glyphs or plain text are used.
-- Over SSH into a VM the terminal usually has no Nerd Font, and unconfigured
-- icons render as replacement boxes, which is worse than no icons at all.
local nerd = vim.g.have_nerd_font == true

try('devicons', function()
  require('nvim-web-devicons').setup { default = true }
end)

-- Buffer manager -------------------------------------------------------------
try('barbar', function()
  require('barbar').setup {
    animation = false, -- pointless latency over SSH
    auto_hide = false,
    tabpages = true,
    clickable = true,
    icons = {
      buffer_index = true,          -- numbered, so <leader>1..9 makes sense
      button = nerd and '' or 'x',
      filetype = { enabled = nerd },
      separator = { left = nerd and '▎' or '|', right = '' },
      modified = { button = nerd and '●' or '+' },
      gitsigns = { added = { enabled = false }, changed = { enabled = false }, deleted = { enabled = false } },
    },
    sidebar_filetypes = { ['neo-tree'] = { event = 'BufWipeout' } },
  }
end)

-- Directory managers ---------------------------------------------------------
try('oil', function()
  require('oil').setup {
    default_file_explorer = true,
    columns = nerd and { 'icon' } or {},
    view_options = { show_hidden = true },
    -- Edit a directory like text: dd to delete, p to move, then :w to apply.
    keymaps = { ['<C-h>'] = false, ['<C-l>'] = false }, -- keep window navigation
  }
end)

try('neo-tree', function()
  require('neo-tree').setup {
    close_if_last_window = true,
    popup_border_style = 'rounded',
    enable_git_status = true,
    enable_diagnostics = true,
    default_component_configs = {
      icon = nerd and {} or { folder_closed = '+', folder_open = '-', folder_empty = ' ', default = ' ' },
      git_status = { symbols = nerd and {} or {
        added = 'A', modified = 'M', deleted = 'D', renamed = 'R',
        untracked = '?', ignored = 'I', unstaged = 'U', staged = 'S', conflict = 'C',
      } },
    },
    window = { width = 32 },
    filesystem = {
      follow_current_file = { enabled = true },
      use_libuv_file_watcher = true,
      filtered_items = { visible = true, hide_dotfiles = false, hide_gitignored = true },
    },
  }
end)

-- Colorizer ------------------------------------------------------------------
try('colorizer', function()
  require('colorizer').setup {
    user_default_options = { css = true, tailwind = true, names = false },
  }
end)

-- Rainbow parentheses --------------------------------------------------------
-- Configured through vim.g.rainbow_delimiters, which is the plugin's own
-- documented interface (`:h g:rainbow_delimiters`), rather than the setup()
-- helper. That is not just style: the plugin's health check opens with
--
--     if not settings then
--         return
--         info("No custom configuration; ...")
--     end
--
-- -- the `return` sits ABOVE the `info` call, so with no global set it emits
-- nothing at all, and Neovim reports
--     ERROR The healthcheck report for "rainbow-delimiters" plugin is empty.
-- Setting the global explicitly gives the check something to report on, and
-- the dead-code branch is never reached.
try('rainbow-delimiters', function()
  local rd = require 'rainbow-delimiters'
  vim.g.rainbow_delimiters = {
    strategy = { [''] = rd.strategy['global'] },
    query = { [''] = 'rainbow-delimiters', lua = 'rainbow-blocks' },
    priority = { [''] = 110 },
    highlight = {
      'RainbowDelimiterRed',
      'RainbowDelimiterYellow',
      'RainbowDelimiterBlue',
      'RainbowDelimiterOrange',
      'RainbowDelimiterGreen',
      'RainbowDelimiterViolet',
      'RainbowDelimiterCyan',
    },
  }
end)

-- Indentation guides ---------------------------------------------------------
try('indent-blankline', function()
  require('ibl').setup {
    indent = { char = '│' },
    scope = { enabled = true, show_start = false, show_end = false },
    exclude = { filetypes = { 'help', 'neo-tree', 'lazy', 'mason', 'checkhealth', 'oil' } },
  }
end)

-- Movement -------------------------------------------------------------------
try('leap', function()
  local leap = require 'leap'
  -- The mapping helper was renamed; support both so a leap update cannot
  -- silently leave the plugin installed but unmapped.
  if type(leap.create_default_mappings) == 'function' then
    leap.create_default_mappings()
  elseif type(leap.add_default_mappings) == 'function' then
    leap.add_default_mappings()
  else
    error 'leap exposes neither create_default_mappings nor add_default_mappings'
  end
end)

-- mini.move and mini.cursorword ship inside mini.nvim, which kickstart already
-- installs — so these are setup calls, not new downloads.
try('mini.move', function() require('mini.move').setup {} end)
try('mini.cursorword', function() require('mini.cursorword').setup { delay = 250 } end)

-- Treesitter context ---------------------------------------------------------
try('treesitter-context', function()
  require('treesitter-context').setup { max_lines = 3, multiline_threshold = 1 }
end)

-- Quality of life ------------------------------------------------------------
try('bullets', function()
  vim.g.bullets_enabled_file_types = { 'markdown', 'text', 'gitcommit', 'scratch' }
  vim.g.bullets_set_mappings = 1
end)

-- :B2BExtras and the startup warning live in 05-b2b-pack.lua, which sees every
-- layer's specs and problems rather than only this file's.
LUAEOF
	chmod 644 "${cfg}/plugin/10-b2b-plugins.lua"
}

# ── VS Code muscle memory ───────────────────────────────────────────────────
write_keymaps_lua() {
	local cfg="$1"
	cat > "${cfg}/plugin/20-b2b-keymaps.lua" <<'LUAEOF'
-- 20-b2b-keymaps.lua — the VS Code bindings worth keeping.
--
-- The point of these is transition, not permanence: they let you work at full
-- speed on day one while the Vim motions become automatic. Every one of them
-- has a native equivalent noted beside it — when a binding starts feeling
-- redundant, delete the line and use the native one.
--
-- TERMINAL CAVEATS, because two of these are famous for "not working":
--
--   Ctrl+/   Terminals traditionally transmit Ctrl+/ as Ctrl+_ (0x1f). Modern
--            ones (kitty, wezterm, foot, and Ghostty) can send a real <C-/>
--            through the kitty keyboard protocol. Both are mapped, so it works
--            either way.
--   Ctrl+S   The tty eats it as XOFF (terminal flow control) before Neovim ever
--            sees it. /etc/profile.d/nvim.sh runs `stty -ixon` for interactive
--            shells to free it up.
--   Ctrl+Shift+F  Most terminals cannot distinguish this from Ctrl+F at all --
--            there is no escape sequence for it outside the kitty protocol. It
--            is mapped for terminals that can, and <leader>sg (kickstart's own
--            grep binding) always works.

local map = function(mode, lhs, rhs, desc)
  vim.keymap.set(mode, lhs, rhs, { desc = desc, silent = true, noremap = true })
end

-- Does a command exist? Several of these depend on a plugin that may have
-- failed to install; binding a key to a missing command produces a confusing
-- error at press time rather than at startup.
local function has(cmd) return vim.fn.exists(':' .. cmd) == 2 end

-- ── Files and text: Ctrl+P and Ctrl+Shift+F ────────────────────────────────
-- Prefer telescope (kickstart's own, already configured); fall back to fzf.
local function find_files()
  if pcall(require, 'telescope.builtin') then
    -- Inside a git repo, git_files skips node_modules and friends for free.
    local builtin = require 'telescope.builtin'
    if vim.fn.isdirectory '.git' == 1 then builtin.git_files { show_untracked = true }
    else builtin.find_files() end
  elseif has 'Files' then vim.cmd 'Files'
  else vim.cmd 'edit .' end
end

local function grep_text()
  if pcall(require, 'telescope.builtin') then require('telescope.builtin').live_grep()
  elseif has 'Rg' then vim.cmd 'Rg'
  else vim.ui.input({ prompt = 'grep: ' }, function(q) if q then vim.cmd('silent grep! ' .. q) vim.cmd 'copen' end end) end
end

map('n', '<C-p>', find_files, 'VS Code: quick open file')
map('i', '<C-p>', function() vim.cmd 'stopinsert' find_files() end, 'VS Code: quick open file')
map('n', '<C-S-f>', grep_text, 'VS Code: search across files')
map('n', '<leader>sg', grep_text, '[S]earch by [G]rep')

-- ── Comment toggle: Ctrl+/ ─────────────────────────────────────────────────
-- Native equivalent: gcc (line) and gc (visual selection), built into Neovim
-- since 0.10 — no plugin involved.
-- `gcc` and `gc` are themselves mappings, so these MUST be recursive: with
-- noremap the right-hand side would be taken as the literal built-in `g`
-- commands and do nothing useful.
for _, lhs in ipairs { '<C-_>', '<C-/>' } do
  vim.keymap.set('n', lhs, 'gcc', { remap = true, silent = true, desc = 'VS Code: toggle comment' })
  vim.keymap.set('x', lhs, 'gc', { remap = true, silent = true, desc = 'VS Code: toggle comment' })
end

-- ── Sidebar: Ctrl+B ────────────────────────────────────────────────────────
map('n', '<C-b>', function()
  if has 'Neotree' then vim.cmd 'Neotree toggle' else vim.cmd 'Oil' end
end, 'VS Code: toggle sidebar')
map('n', '<leader>e', function()
  if has 'Neotree' then vim.cmd 'Neotree reveal' else vim.cmd 'Oil' end
end, 'File [e]xplorer, revealing the current file')

-- oil's own convention: `-` opens the PARENT directory as an editable buffer.
map('n', '-', function()
  if has 'Oil' then vim.cmd 'Oil' else vim.cmd 'edit .' end
end, 'Open parent directory (oil)')

-- ── Save: Ctrl+S ───────────────────────────────────────────────────────────
map('n', '<C-s>', '<cmd>write<CR>', 'VS Code: save')
map('i', '<C-s>', '<Esc><cmd>write<CR>', 'VS Code: save')
map('x', '<C-s>', '<Esc><cmd>write<CR>', 'VS Code: save')

-- ── Buffers: the tab bar (barbar) ──────────────────────────────────────────
-- Native equivalent: :bnext / :bprev / :bdelete.
if has 'BufferNext' then
  map('n', '<A-,>', '<cmd>BufferPrevious<CR>', 'Buffer: previous')
  map('n', '<A-.>', '<cmd>BufferNext<CR>', 'Buffer: next')
  map('n', '<A-<>', '<cmd>BufferMovePrevious<CR>', 'Buffer: move left')
  map('n', '<A->>', '<cmd>BufferMoveNext<CR>', 'Buffer: move right')
  map('n', '<A-c>', '<cmd>BufferClose<CR>', 'Buffer: close')
  map('n', '<A-p>', '<cmd>BufferPin<CR>', 'Buffer: pin')
  map('n', '<leader>bb', '<cmd>BufferPick<CR>', '[B]uffer pick')
  map('n', '<leader>bo', '<cmd>BufferCloseAllButCurrent<CR>', '[B]uffers: close [o]thers')
  -- Alt+1..9 jumps straight to a numbered tab, like VS Code's Ctrl+1..9.
  for i = 1, 9 do
    map('n', ('<A-%d>'):format(i), ('<cmd>BufferGoto %d<CR>'):format(i), ('Buffer: go to %d'):format(i))
  end
  map('n', '<A-0>', '<cmd>BufferLast<CR>', 'Buffer: last')
end

-- ── Git ────────────────────────────────────────────────────────────────────
-- kickstart already provides gitsigns hunk bindings; these add the rest.
if has 'Git' then
  map('n', '<leader>gs', '<cmd>Git<CR>', '[G]it [s]tatus (fugitive)')
  map('n', '<leader>gc', '<cmd>Git commit<CR>', '[G]it [c]ommit')
  map('n', '<leader>gd', '<cmd>Gdiffsplit<CR>', '[G]it [d]iff against index')
  map('n', '<leader>gB', '<cmd>Git blame<CR>', '[G]it [B]lame')
end
if has 'Flog' then
  map('n', '<leader>gl', '<cmd>Flog<CR>', '[G]it [l]og graph (flog)')
  map('n', '<leader>gL', '<cmd>Flog -all<CR>', '[G]it [L]og, all branches')
end

-- ── fzf, beside telescope ──────────────────────────────────────────────────
-- These live under <leader>z, not the more obvious <leader>f, because
-- kickstart binds <leader>f itself to "format buffer". Nesting anything below
-- a mapping that is already complete does not shadow it, but it does make it
-- WAIT: Neovim has to hold <leader>f for 'timeoutlen' (1s by default) to find
-- out whether an f is coming, so every format would pause for a second. z is
-- free, and reads as fZf.
if has 'Files' then
  map('n', '<leader>zf', '<cmd>Files<CR>', 'f[z]f [f]iles')
  map('n', '<leader>zg', '<cmd>Rg<CR>', 'f[z]f [g]rep (ripgrep)')
  map('n', '<leader>zb', '<cmd>Buffers<CR>', 'f[z]f [b]uffers')
  map('n', '<leader>zl', '<cmd>BLines<CR>', 'f[z]f [l]ines in this buffer')
  map('n', '<leader>zc', '<cmd>Commits<CR>', 'f[z]f [c]ommits')
end

-- ── Alignment and context ──────────────────────────────────────────────────
-- ga in visual mode, then a delimiter: `=`, `:`, or <Space>.
-- <Plug> mappings are by definition indirections, so they need remap as well.
vim.keymap.set('x', 'ga', '<Plug>(EasyAlign)', { remap = true, silent = true, desc = 'Easy[a]lign selection' })
vim.keymap.set('n', 'ga', '<Plug>(EasyAlign)', { remap = true, silent = true, desc = 'Easy[a]lign motion' })

if has 'TSContextToggle' then
  map('n', '<leader>tc', '<cmd>TSContextToggle<CR>', '[T]oggle treesitter [c]ontext')
end
LUAEOF
	chmod 644 "${cfg}/plugin/20-b2b-keymaps.lua"
}

# ── Session management (the VS Code "workspace" equivalent) ─────────────────
write_sessions_lua() {
	local cfg="$1" sessdir="$2"
	cat > "${cfg}/plugin/30-b2b-sessions.lua" <<LUAEOF
-- 30-b2b-sessions.lua — sessions that behave like VS Code workspaces.
--
-- Neovim's built-in :mksession writes a one-shot snapshot. tpope's vim-obsession
-- turns it into a LIVE session file: once started it keeps rewriting itself as
-- you open buffers, split windows and change directory, so quitting and coming
-- back lands you exactly where you left off. That is the behaviour people
-- actually mean when they say "VS Code workspace".
--
-- The workflow this is built for is the remote one: everything runs inside tmux
-- on the VM, so a session survives the SSH connection dropping AND survives
-- closing the laptop. Reconnect, re-attach to tmux, and Neovim is still there;
-- if even tmux died, \`vw <name>\` restores the session from disk.
--
--   <leader>sS   start (or rename) a session for this project
--   <leader>sX   stop recording -- the file stays, it just stops updating
--   <leader>sF   pick a saved session and load it
--   :B2BSession [name]   same as <leader>sS, with the name on the command line
--   vw <name>            from the shell: open a saved session directly
--
-- Sessions live in ${sessdir}.

local session_dir = vim.fn.expand '${sessdir}'
vim.fn.mkdir(session_dir, 'p')

-- Save enough for the session to be worth restoring. 'options' is deliberately
-- absent: baking option values into a session file means a later config change
-- is silently overridden by every old session, which is a genuinely baffling
-- bug to chase.
vim.o.sessionoptions = 'blank,buffers,curdir,folds,help,tabpages,winsize,winpos,terminal,localoptions'

-- Default the name to the project directory, because that is what it almost
-- always is: ~/work/api -> "api".
local function default_name()
  return vim.fn.fnamemodify(vim.fn.getcwd(), ':t')
end

local function start_session(name)
  name = (name and name ~= '') and name or default_name()
  if vim.fn.exists ':Obsession' ~= 2 then
    vim.notify('vim-obsession is not installed — run :B2BExtras', vim.log.levels.ERROR)
    return
  end
  local path = session_dir .. '/' .. name
  vim.cmd('Obsession ' .. vim.fn.fnameescape(path))
  vim.notify('session recording to ' .. path, vim.log.levels.INFO)
end

vim.api.nvim_create_user_command('B2BSession', function(opts)
  start_session(opts.args)
end, { nargs = '?', desc = 'Start recording a Neovim session (VS Code workspace)' })

vim.keymap.set('n', '<leader>sS', function()
  vim.ui.input({ prompt = 'Session name: ', default = default_name() }, function(name)
    if name then start_session(name) end
  end)
end, { desc = '[S]ession: [S]tart recording' })

vim.keymap.set('n', '<leader>sX', function()
  if vim.fn.exists ':Obsession' == 2 then
    vim.cmd 'Obsession!'
    vim.notify('session recording stopped (the file is kept)', vim.log.levels.INFO)
  end
end, { desc = '[S]ession: stop ([X]) recording' })

vim.keymap.set('n', '<leader>sF', function()
  local files = vim.fn.readdir(session_dir, function(n) return vim.fn.isdirectory(session_dir .. '/' .. n) == 0 end)
  if not files or #files == 0 then
    vim.notify('no saved sessions in ' .. session_dir, vim.log.levels.WARN)
    return
  end
  vim.ui.select(files, { prompt = 'Load session:' }, function(choice)
    if choice then vim.cmd('source ' .. vim.fn.fnameescape(session_dir .. '/' .. choice)) end
  end)
end, { desc = '[S]ession: [F]ind and load' })
LUAEOF
	chmod 644 "${cfg}/plugin/30-b2b-sessions.lua"
}

# ── The `vw` shell command ──────────────────────────────────────────────────
# itsjfx's original is two lines: `nvim -S ~/.nvim-sessions/$1`. It is expanded
# here for the shell this VM actually runs.
#
# THE COMPLETION PROBLEM: the original ships a zsh completion (#compdef). This
# VM's login shell is hellish, which has NO programmable completion at all --
# `complete` and `compgen` are not implemented (its own rc.d/70-completion.hsh
# documents this and keeps a registry for the day they land). So tab-completion
# of session names cannot work there no matter what is installed.
#
# The fix is to make the command usable WITHOUT completion: `vw` with no
# arguments lists every session with the directory it was recorded in -- the
# same information the zsh completion showed in its descriptions. A bash
# completion is installed as well, for anyone using bash.
write_vw() {
	local sessdir_rel="$1"
	cat > /usr/local/bin/vw <<VWEOF
#!/usr/bin/env bash
# vw — open a saved Neovim session ("workspace").
#
# After itsjfx/dotfiles bin/vw, extended to list sessions when called with no
# arguments, because this VM's login shell cannot do tab completion.
#
#   vw              list saved sessions and the directory each was recorded in
#   vw <name>       open that session
#   vw <name> file  open it, then also open <file>

set -u
SESSION_DIR="\${NVIM_SESSION_DIR:-\$HOME/${sessdir_rel}}"

list_sessions() {
	if [ ! -d "\$SESSION_DIR" ] || [ -z "\$(ls -A "\$SESSION_DIR" 2>/dev/null)" ]; then
		echo "No sessions yet in \$SESSION_DIR."
		echo "Start one from inside Neovim with  <leader>sS  or  :B2BSession <name>"
		return 0
	fi
	printf '%-24s %s\n' "SESSION" "DIRECTORY"
	local f dir
	for f in "\$SESSION_DIR"/*; do
		[ -f "\$f" ] || continue
		# An Obsession file records the working directory as a \`cd\` line.
		dir=\$(grep -m1 '^cd ' "\$f" 2>/dev/null | cut -d' ' -f2- || true)
		printf '%-24s %s\n' "\$(basename "\$f")" "\${dir:-?}"
	done
}

case "\${1:-}" in
	'' | -l | --list)
		list_sessions
		exit 0
		;;
	-h | --help)
		# Print the leading comment block, whatever length it grows to: a fixed
		# line range silently starts printing code the moment the header is
		# edited (it was printing 'set -u' and the SESSION_DIR line).
		awk 'NR > 1 { if (!/^#/) exit; sub(/^# ?/, ""); print }' "\$0"
		exit 0
		;;
esac

session="\$1"
shift
if [ ! -f "\$SESSION_DIR/\$session" ]; then
	echo "vw: no session named '\$session' in \$SESSION_DIR" >&2
	echo >&2
	list_sessions >&2
	exit 1
fi

echo "Launching \$session nvim session..." >&2
exec nvim -S "\$SESSION_DIR/\$session" "\$@"
VWEOF
	chmod 755 /usr/local/bin/vw

	# Bash completion, for bash users. Ported from the zsh #compdef original.
	mkdir -p /etc/bash_completion.d
	cat > /etc/bash_completion.d/vw <<VWCEOF
# bash completion for vw — see /usr/local/bin/vw
_vw() {
	local dir="\${NVIM_SESSION_DIR:-\$HOME/${sessdir_rel}}"
	[ -d "\$dir" ] || return 0
	COMPREPLY=(\$(compgen -W "\$(cd "\$dir" && ls -1 2>/dev/null)" -- "\${COMP_WORDS[COMP_CWORD]}"))
}
complete -F _vw vw
VWCEOF
	chmod 644 /etc/bash_completion.d/vw
}

# ── Startup: make the IDE visible ───────────────────────────────────────────
write_startup_lua() {
	local cfg="$1"
	cat > "${cfg}/plugin/40-b2b-startup.lua" <<'LUAEOF'
-- 40-b2b-startup.lua — make the editor LOOK like the editor you configured.
--
-- Everything in 10-b2b-plugins.lua loads correctly, but almost none of it
-- SHOWS anything until you ask: neo-tree is a toggle, oil opens on demand, the
-- tab bar is empty until a second buffer exists. So a bare `nvim` rendered the
-- stock Neovim splash screen and looked exactly like an unconfigured install.
--
-- This file fixes the first impression:
--   * the file tree opens by itself, so navigation is there from the start;
--   * the splash screen is replaced by a start page that lists the keys, so
--     the bindings are discoverable instead of being something you have to
--     remember from a README.
--
-- WHEN IT DOES NOT RUN, and why that matters more than when it does:
-- auto-opening a sidebar unconditionally is genuinely destructive. `nvim` is
-- this VM's $EDITOR, so `git commit` runs it -- opening a file tree beside a
-- commit message, and worse, leaving a window open that git then waits on. The
-- guards below are the point of the file, not an afterthought.

local M = {}

-- ── When to stay out of the way ────────────────────────────────────────────
-- The single most important check in this file. `nvim` is this VM's $EDITOR,
-- so git runs it for commit messages, rebase todos and merge conflicts. Every
-- one of those passes a FILE ARGUMENT, so "only greet when there are no
-- arguments" is not enough on its own to make opening a sidebar safe -- and a
-- sidebar over a commit message is not just ugly, it leaves an extra window
-- that git then waits on.
--
-- Git also exports GIT_EXEC_PATH / GIT_INDEX_FILE into the editor it spawns,
-- which is a far more reliable signal than pattern-matching filenames, so that
-- is checked first and the name patterns are only a backstop.
local function is_git_editor()
  if vim.env.GIT_EXEC_PATH or vim.env.GIT_INDEX_FILE then return true end
  local name = vim.api.nvim_buf_get_name(0)
  if name:match '%.git[/\\]' then return true end
  return name:match 'COMMIT_EDITMSG$' ~= nil
    or name:match 'MERGE_MSG$' ~= nil
    or name:match 'TAG_EDITMSG$' ~= nil
    or name:match 'git%-rebase%-todo$' ~= nil
end

-- Never take over one of these buffers.
local SKIP_FILETYPES = {
  gitcommit = true, gitrebase = true, ['git'] = true,
  help = true, man = true, ['checkhealth'] = true, ['qf'] = true,
}

-- Is this an ordinary editing session we may decorate at all?
local function may_decorate()
  if vim.o.diff then return false end                       -- nvim -d
  if vim.g.SessionLoad or vim.v.this_session ~= '' then return false end
  if is_git_editor() then return false end
  if SKIP_FILETYPES[vim.bo.filetype] then return false end
  if vim.bo.buftype ~= '' then return false end             -- terminal, quickfix, prompt
  -- Content arriving on stdin (`cat x | nvim -`).
  if vim.fn.argc() == 0 and vim.api.nvim_buf_get_name(0) == ''
    and vim.api.nvim_buf_line_count(0) > 1 then return false end
  return true
end

-- The start page replaces the splash screen, so it is only for a bare `nvim`
-- with nothing to show yet.
local function should_greet()
  if not may_decorate() then return false end
  if vim.fn.argc() > 0 then return false end
  if vim.api.nvim_buf_get_name(0) ~= '' then return false end
  if vim.api.nvim_buf_line_count(0) > 1 then return false end
  return (vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] or '') == ''
end

-- The tree, by contrast, is wanted for real work too -- `nvim src/main.c`
-- should still look like an editor with a project in it, which is the whole
-- point of the VS Code layout. It just must not steal the cursor.
local function should_open_tree()
  if not may_decorate() then return false end
  if vim.fn.argc() > 1 then return false end   -- nvim *.c: the user wants buffers, not a tree
  return true
end

-- ── The start page ─────────────────────────────────────────────────────────
local function recent_files(n)
  local out = {}
  for _, f in ipairs(vim.v.oldfiles or {}) do
    if #out >= n then break end
    if vim.fn.filereadable(f) == 1 and not f:match '/%.git/' and not f:match '/nvim/doc/' then
      table.insert(out, f)
    end
  end
  return out
end

local LOGO = {
  '███╗   ██╗██╗   ██╗██╗███╗   ███╗',
  '████╗  ██║██║   ██║██║████╗ ████║',
  '██╔██╗ ██║██║   ██║██║██╔████╔██║',
  '██║╚██╗██║╚██╗ ██╔╝██║██║╚██╔╝██║',
  '██║ ╚████║ ╚████╔╝ ██║██║ ╚═╝ ██║',
  '╚═╝  ╚═══╝  ╚═══╝  ╚═╝╚═╝     ╚═╝',
}

local KEYS = {
  { 'Ctrl+P', 'find a file' },
  { 'Ctrl+B', 'toggle the file tree' },
  { 'Ctrl+/', 'comment a line' },
  { 'Ctrl+S', 'save' },
  { 'Ctrl+\\', 'terminal' },
  { 'Alt+1..9', 'jump to a buffer tab' },
  { '-', 'edit this directory as text (oil)' },
  { '<Space>sg', 'grep the project (telescope)' },
  { '<Space>gg', 'lazygit' },
  { '<Space>o', 'symbol outline' },
  { '<Space>mr', 'render markdown in the buffer' },
  { '<Space>mp', 'markdown preview in a browser' },
  { 'F5 / F9', 'debug: continue / breakpoint' },
  { '<Space>rt', 'run the nearest test' },
  { '<Space>sS', 'start a session here' },
  { ':B2BExtras', 'what is installed' },
  { ':B2BMarkdown', 'how to see the preview' },
  { ':checkhealth', 'is anything broken' },
}

function M.start_page()
  -- Rows are built first, then centred as ONE BLOCK. Centring each line on its
  -- own -- the obvious way, and the way this was written first -- ragged-edges
  -- a two-column key list into an unreadable zigzag, because every line has a
  -- different length.
  local rows = {}
  local function add(text, hl, action) rows[#rows + 1] = { text = text or '', hl = hl, action = action } end

  for _, l in ipairs(LOGO) do add(l, 'B2BStartLogo') end
  add ''
  local v = vim.version()
  add(('born2root  ·  nvim %d.%d.%d'):format(v.major, v.minor, v.patch), 'B2BStartHeader')
  add ''

  for _, k in ipairs(KEYS) do
    add(('%-13s %s'):format(k[1], k[2]), 'B2BStartKey')
  end

  local recents = recent_files(5)
  if #recents > 0 then
    add ''
    add('── recent ──', 'B2BStartHeader')
    for i, f in ipairs(recents) do
      local short = vim.fn.fnamemodify(f, ':~')
      if #short > 46 then short = '…' .. short:sub(-45) end
      add(('%d  %s'):format(i, short), 'B2BStartFile', function() vim.cmd.edit(vim.fn.fnameescape(f)) end)
    end
  end
  add ''
  add('q quit   e new file', 'B2BStartKey')

  -- Centre the block in the window we are actually in, which is narrower than
  -- the screen once the tree has taken its 32 columns.
  local win_w = vim.api.nvim_win_get_width(0)
  local block_w = 0
  for _, r in ipairs(rows) do block_w = math.max(block_w, vim.fn.strdisplaywidth(r.text)) end
  local left = math.max(math.floor((win_w - block_w) / 2), 0)
  local pad = string.rep(' ', left)

  local win_h = vim.api.nvim_win_get_height(0)
  local top = math.max(math.floor((win_h - #rows) / 2), 0)

  local lines = {}
  for _ = 1, top do lines[#lines + 1] = '' end
  for _, r in ipairs(rows) do lines[#lines + 1] = (r.text == '') and '' or (pad .. r.text) end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].buflisted = false
  vim.bo[buf].filetype = 'b2bstart'

  local prev = vim.api.nvim_get_current_buf()
  vim.api.nvim_win_set_buf(0, buf)

  -- Wipe the empty [No Name] buffer Neovim started with. Without this barbar
  -- shows a phantom "[buffer 1]" tab before a single file has been opened.
  if prev ~= buf and vim.api.nvim_buf_is_valid(prev)
    and vim.api.nvim_buf_get_name(prev) == ''
    and not vim.bo[prev].modified
  then
    pcall(vim.api.nvim_buf_delete, prev, { force = true })
  end

  vim.wo.number = false
  vim.wo.relativenumber = false
  vim.wo.signcolumn = 'no'
  vim.wo.cursorline = false
  vim.wo.list = false
  vim.wo.wrap = false
  vim.wo.fillchars = 'eob: '

  local ns = vim.api.nvim_create_namespace 'b2bstart'
  for i, r in ipairs(rows) do
    if r.hl then
      vim.api.nvim_buf_set_extmark(buf, ns, top + i - 1, 0, { end_col = #lines[top + i], hl_group = r.hl })
    end
    if r.action then
      local n = r.text:match '^(%d)'
      if n then vim.keymap.set('n', n, r.action, { buffer = buf, silent = true, nowait = true }) end
    end
  end

  vim.keymap.set('n', 'q', '<cmd>qa<CR>', { buffer = buf, silent = true, nowait = true })
  vim.keymap.set('n', 'e', '<cmd>enew<CR>', { buffer = buf, silent = true, nowait = true })
  vim.api.nvim_win_set_cursor(0, { math.min(top + 1, #lines), 0 })
end

-- Link to the colourscheme rather than hardcoding colours, so this follows
-- whatever theme kickstart is set to instead of fighting it.
local function set_highlights()
  vim.api.nvim_set_hl(0, 'B2BStartLogo', { link = 'Function', default = true })
  vim.api.nvim_set_hl(0, 'B2BStartHeader', { link = 'Title', default = true })
  vim.api.nvim_set_hl(0, 'B2BStartKey', { link = 'Comment', default = true })
  vim.api.nvim_set_hl(0, 'B2BStartFile', { link = 'Directory', default = true })
end
set_highlights()
vim.api.nvim_create_autocmd('ColorScheme', {
  group = vim.api.nvim_create_augroup('b2b-start-hl', { clear = true }),
  callback = set_highlights,
})

-- ── Wire it to startup ─────────────────────────────────────────────────────
vim.api.nvim_create_autocmd('VimEnter', {
  group = vim.api.nvim_create_augroup('b2b-startup', { clear = true }),
  nested = true,
  callback = function()
    -- BOTH decisions are made BEFORE anything is touched, and that ordering is
    -- the whole bug this comment exists to prevent coming back: start_page()
    -- sets buftype=nofile on the current buffer, and should_open_tree()'s
    -- guard rejects a non-empty buftype. Asking it afterwards therefore always
    -- answered "no" -- the start page appeared, the tree silently never did.
    local greet = should_greet()
    local tree = should_open_tree()

    if greet then pcall(M.start_page) end

    -- The tree goes up last and focus is handed straight back, so the cursor
    -- ends up in the file you asked for -- not in the sidebar, which is the
    -- thing that makes auto-opened trees infuriating.
    if tree and vim.fn.exists ':Neotree' == 2 then
      local win = vim.api.nvim_get_current_win()
      pcall(vim.cmd, 'Neotree show left')
      if vim.api.nvim_win_is_valid(win) then vim.api.nvim_set_current_win(win) end
    end
  end,
})

-- Keep the sidebar and the start page out of the tab bar: they are windows,
-- not documents, and barbar listing them puts tabs on screen before a single
-- file has been opened.
vim.api.nvim_create_autocmd('FileType', {
  group = vim.api.nvim_create_augroup('b2b-startup-nobuffer', { clear = true }),
  pattern = { 'b2bstart', 'neo-tree' },
  callback = function(ev) vim.bo[ev.buf].buflisted = false end,
})

-- `:B2BStart` brings it back on demand.
vim.api.nvim_create_user_command('B2BStart', function() M.start_page() end,
  { desc = 'Open the born2root start page' })

return M
LUAEOF
	chmod 644 "${cfg}/plugin/40-b2b-startup.lua"
}

# ── Markdown: rendered in the buffer, and rendered in a browser ─────────────
# The two plugins answer different questions and are both worth having:
#
#   render-markdown.nvim   you are still EDITING the markdown; headings, bullets,
#                          tables, code blocks and checkboxes are just drawn
#                          properly while you type. No second window, no browser.
#   markdown-preview.nvim  the real rendered page — mermaid diagrams, KaTeX
#                          maths, images — served over HTTP and refreshed live.
#
# THE HEADLESS PROBLEM, and why this is not just two vim.pack lines.
# markdown-preview starts a web server and then launches a browser at it. This
# VM has neither a browser nor an X display, so the launch fails and the URL
# scrolls past in an error. The config below turns that around: the server binds
# to 127.0.0.1 only, on a FIXED port so one SSH tunnel keeps working, the browser
# launch is replaced by /bin/true when there is no display, and the URL is
# echoed instead. `:B2BMarkdown` prints the tunnel command to run on the host.
#
# Binding to localhost rather than setting mkdp_open_to_the_world is deliberate:
# this VM runs UFW with a deliberately short allow-list, and the alternative is
# either punching a hole in it or being confused about why the port is refused.
# An SSH tunnel needs neither.
write_markdown_lua() {
	local cfg="$1" port="$2"
	# A tiny interpolated head, then a literal body: the Lua below contains
	# backslashes and $-signs that an unquoted heredoc would eat.
	cat > "${cfg}/plugin/50-b2b-markdown.lua" <<LUAHEAD
-- 50-b2b-markdown.lua — written by setup/install/nvim/install_nvim_extras.sh
local PORT = '${port}'
local SSH_PORT = '4242'
LUAHEAD
	cat >> "${cfg}/plugin/50-b2b-markdown.lua" <<'LUAEOF'

-- The markdown layer: render-markdown.nvim in the buffer, markdown-preview.nvim
-- in a browser. See the installer header for why the preview needs a tunnel.
--
--   <leader>mp   start/stop the browser preview
--   <leader>mr   toggle in-buffer rendering
--   :B2BMarkdown how to reach the preview from the host

local B2B = _G.B2B
if B2B == nil then
  vim.notify('b2b: 05-b2b-pack.lua did not load — markdown layer off', vim.log.levels.ERROR)
  return
end
local gh, try = B2B.gh, B2B.try
local nerd = vim.g.have_nerd_font == true

-- No display means no browser to launch. Same test 00-b2b-local.lua uses for
-- the clipboard, and for the same reason: over SSH there is nothing there.
local headless = vim.env.DISPLAY == nil and vim.env.WAYLAND_DISPLAY == nil

-- ── markdown-preview settings, which MUST be set before the plugin loads ───
-- mkdp is a vimscript plugin: plugin/mkdp.vim reads most of these at source
-- time, so setting them after B2B.add would be setting them too late.
vim.g.mkdp_auto_start = 0        -- opening a .md file must not start a server
-- Do NOT auto-close on leaving the buffer (that is the upstream default). The
-- workflow here is a browser on the HOST showing the page while you keep working
-- in the VM; auto-close tears the preview down the moment you switch to another
-- file, which looks like the tunnel broke. <leader>mp closes it deliberately.
vim.g.mkdp_auto_close = 0
vim.g.mkdp_refresh_slow = 0      -- re-render as you type, not just on save
vim.g.mkdp_command_for_global = 0
vim.g.mkdp_open_to_the_world = 0 -- 127.0.0.1 only — reach it through the tunnel
vim.g.mkdp_port = PORT
vim.g.mkdp_echo_preview_url = 1  -- the whole point on a headless box
vim.g.mkdp_filetypes = { 'markdown' }
vim.g.mkdp_theme = 'dark'
vim.g.mkdp_page_title = '「${name}」'

-- Replace the browser launch with /bin/true when there is nothing to launch.
-- Without this every preview prints a failed xdg-open over the URL you wanted.
if headless then vim.g.mkdp_browser = 'true' end

-- Mermaid, KaTeX, PlantUML and the flow/sequence diagram renderers are all
-- switched on by naming them here: an empty table means "default options",
-- and a key left out entirely means the renderer is not loaded at all.
vim.g.mkdp_preview_options = {
  mkit = {},               -- markdown-it
  katex = {},              -- $...$ maths
  uml = {},                -- PlantUML
  maid = {},               -- mermaid  ```mermaid graph TD; A-->B;  ```
  disable_sync_scroll = 0,
  sync_scroll_type = 'middle',
  hide_yaml_meta = 1,
  sequence_diagrams = {},
  flowchart_diagrams = {},
  content_editable = false,
  disable_filename = 0,
  toc = {},
}

B2B.add {
  { src = gh 'MeanderingProgrammer/render-markdown.nvim' },
  { src = gh 'iamcco/markdown-preview.nvim' },
}

-- ── render-markdown ────────────────────────────────────────────────────────
-- The defaults assume a Nerd Font. Over SSH into this VM the terminal usually
-- has none, and every heading would render as a replacement box — strictly
-- worse than the '#' it replaced. So the icon sets are chosen by the same
-- vim.g.have_nerd_font flag kickstart uses; the bullets, table borders and code
-- block borders are plain box-drawing characters, which any UTF-8 terminal has.
try('render-markdown', function()
  require('render-markdown').setup {
    file_types = { 'markdown', 'codecompanion' },
    -- Completion for callouts and checkboxes through kickstart's blink.cmp.
    completions = { blink = { enabled = true } },
    -- LaTeX rendering shells out to `utftex` or `latex2text`, neither of which
    -- is installed here. Left on, every formula logs a converter-not-found and
    -- :checkhealth reports it as a problem you cannot fix without a TeX stack.
    latex = { enabled = false },
    -- The sign column is two columns wide and duplicates what the heading
    -- already shows; on an 80-column SSH terminal that is worth reclaiming.
    sign = { enabled = false },
    heading = {
      sign = false,
      width = 'block',
      right_pad = 2,
      icons = nerd and { '󰲡 ', '󰲣 ', '󰲥 ', '󰲧 ', '󰲩 ', '󰲫 ' }
        or { '# ', '## ', '### ', '#### ', '##### ', '###### ' },
    },
    code = {
      sign = false,
      width = 'block',
      right_pad = 2,
      border = 'thick',
      language_icon = nerd,
    },
    checkbox = {
      unchecked = { icon = nerd and '󰄱 ' or '[ ] ' },
      checked = { icon = nerd and '󰱒 ' or '[x] ' },
    },
    link = nerd and {} or { image = 'img ', email = 'mail ', hyperlink = 'link ' },
    pipe_table = { preset = 'round' },
  }
end)

-- ── Keymaps ────────────────────────────────────────────────────────────────
-- <leader>m is free: kickstart uses s/t/h/g/f/q, the extras layer uses b/e/g/z.
local function map(lhs, rhs, desc)
  vim.keymap.set('n', lhs, rhs, { desc = desc, silent = true, noremap = true })
end

-- The three ways this can fail all need different answers, and telling them
-- apart is the whole reason this is a function and not a <cmd> string:
--
--   1. the plugin never installed              -> :B2BExtras
--   2. the plugin is fine, the buffer is not.  mkdp registers :MarkdownPreview*
--      as BUFFER-LOCAL commands (`command! -buffer`), from a FileType autocmd
--      that only fires for g:mkdp_filetypes. In a .c file they do not exist,
--      and reporting that as "not installed" sends you debugging the install.
--   3. the plugin is fine and the buffer is fine, but the prebuilt server
--      binary is missing -> the preview would fail with mkdp's own opaque error.
local MKDP_BIN = 'markdown-preview.nvim/app/bin/markdown-preview-linux'
map('<leader>mp', function()
  if not B2B.have 'markdown-preview.nvim' then
    vim.notify('markdown-preview.nvim is not installed — run :B2BExtras', vim.log.levels.ERROR)
    return
  end
  if vim.fn.executable(B2B.pack_root .. MKDP_BIN) ~= 1 then
    vim.notify('the markdown-preview server binary is missing — run :B2BMarkdown', vim.log.levels.ERROR)
    return
  end
  if vim.fn.exists ':MarkdownPreviewToggle' ~= 2 then
    vim.notify(('markdown preview only works in a markdown buffer (this one is %s)')
      :format(vim.bo.filetype ~= '' and vim.bo.filetype or 'untyped'), vim.log.levels.WARN)
    return
  end
  vim.cmd 'MarkdownPreviewToggle'
end, '[M]arkdown: browser [p]review on/off')

map('<leader>mr', function()
  if not B2B.have 'render-markdown.nvim' then
    vim.notify('render-markdown.nvim is not installed — run :B2BExtras', vim.log.levels.ERROR)
    return
  end
  vim.cmd 'RenderMarkdown toggle'
end, '[M]arkdown: in-buffer [r]endering on/off')

-- ── :B2BMarkdown — how to actually see the preview ─────────────────────────
-- This exists because the failure it prevents is silent and baffling: you press
-- <leader>mp, Neovim says the preview is running, and nothing you do on the
-- host reaches it, because the server is on the VM's loopback.
vim.api.nvim_create_user_command('B2BMarkdown', function()
  local plugin_ok = B2B.have 'markdown-preview.nvim'
  local bin = B2B.pack_root .. 'markdown-preview.nvim/app/bin/markdown-preview-linux'
  local bin_ok = vim.fn.executable(bin) == 1
  vim.notify(table.concat({
    'born2root markdown',
    '',
    ('  render-markdown.nvim   %s'):format(B2B.have 'render-markdown.nvim' and 'installed' or 'MISSING'),
    ('  markdown-preview.nvim  %s'):format(plugin_ok and 'installed' or 'MISSING'),
    ('  preview server binary  %s'):format(bin_ok and 'present' or 'MISSING — see below'),
    '',
    '  <leader>mr   toggle in-buffer rendering',
    '  <leader>mp   start/stop the browser preview',
    '',
    'The preview server listens on 127.0.0.1:' .. PORT .. ' INSIDE the VM, so open a',
    'tunnel from your host once per session:',
    '',
    '  ssh -p ' .. SSH_PORT .. ' -L ' .. PORT .. ':127.0.0.1:' .. PORT .. ' ' .. (vim.env.USER or 'dlesieur') .. '@127.0.0.1',
    '',
    'Then press <leader>mp and open the URL it echoes in your host browser.',
    '',
    bin_ok and '' or ('If the binary is missing, install it from inside Neovim with\n'
      .. '  :call mkdp#util#install()\n'
      .. 'or re-run setup/install/nvim/install_nvim_extras.sh from the host.'),
  }, '\n'), vim.log.levels.INFO)
end, { desc = 'How to reach the markdown preview from the host' })
LUAEOF
	chmod 644 "${cfg}/plugin/50-b2b-markdown.lua"
}

# ── The rest of the VS Code feature list ────────────────────────────────────
# linting, debugger, tests, terminal, git UI, outline, breadcrumbs, REST, SQL, AI.
#
# THREE THINGS THIS DELIBERATELY DOES NOT INSTALL:
#
#   * bufferline.nvim — barbar (10-b2b-plugins.lua) is the same feature. Two tab
#     bars fight over the tabline and you get one of them at random.
#   * project.nvim — its last commit is April 2023. What it is actually wanted
#     for here is "cd to the project root", and `vim.fs.root()` has been in
#     Neovim's standard library since 0.10, so that is fifteen lines below
#     instead of a dead dependency. The other half of it, "reopen the project I
#     was working on", is already the session manager in 30-b2b-sessions.lua.
#   * a Mason package for the debugger. gdb has spoken DAP natively since 14
#     (`gdb -i dap`) and trixie ships 16.3, so C and C++ debugging needs the gdb
#     that is already installed — no codelldb download, no rust toolchain.
#
# MEMORY. The note at the top of this file about a 2 GB VM applies harder here:
# a language server, a debug session and a test run at once is more than this
# box wants. They are all lazy — nothing below starts a process until you press
# its key — but if you routinely run several, give the VM more RAM.
write_ide_lua() {
	local cfg="$1" venv="$2"
	cat > "${cfg}/plugin/60-b2b-ide.lua" <<LUAHEAD
-- 60-b2b-ide.lua — written by setup/install/nvim/install_nvim_extras.sh
local VENV = '${venv}'
LUAHEAD
	cat >> "${cfg}/plugin/60-b2b-ide.lua" <<'LUAEOF'

-- The IDE layer: everything on the "VS Code equivalent" list that kickstart and
-- 10-b2b-plugins.lua do not already cover.
--
--   <leader>d…   debugger (nvim-dap)          F5 continue, F9 breakpoint
--   <leader>r…   test runner (neotest)
--   <leader>o    symbol outline (aerial)
--   <leader>gg   lazygit
--   <C-\>        terminal
--   <leader>k…   REST client (kulala) — run .http files
--   <leader>D    SQL client (dadbod-ui)
--   <leader>a…   AI assistant (codecompanion), when a backend is configured
--
-- Autocomplete, go-to-definition, find-references, inline diagnostics, rename
-- and format-on-demand are NOT here: kickstart already ships all six.

local B2B = _G.B2B
if B2B == nil then
  vim.notify('b2b: 05-b2b-pack.lua did not load — IDE layer off', vim.log.levels.ERROR)
  return
end
local gh, try = B2B.gh, B2B.try

local function map(lhs, rhs, desc, mode)
  vim.keymap.set(mode or 'n', lhs, rhs, { desc = desc, silent = true, noremap = true })
end
local function exe(bin) return vim.fn.executable(bin) == 1 end

B2B.add {
  -- linting
  { src = gh 'mfussenegger/nvim-lint' },
  -- debugger. nvim-nio is a shared dependency of dap-ui AND neotest.
  { src = gh 'mfussenegger/nvim-dap' },
  { src = gh 'nvim-neotest/nvim-nio' },
  { src = gh 'rcarriga/nvim-dap-ui' },
  -- test runner
  { src = gh 'nvim-neotest/neotest' },
  { src = gh 'nvim-neotest/neotest-python' },
  -- terminal (and the host for lazygit)
  { src = gh 'akinsho/toggleterm.nvim' },
  -- symbol outline + breadcrumbs
  { src = gh 'stevearc/aerial.nvim' },
  { src = gh 'SmiteshP/nvim-navic' },
  -- REST client
  { src = gh 'mistweaverco/kulala.nvim' },
  -- SQL client
  { src = gh 'tpope/vim-dadbod' },
  { src = gh 'kristijanhusak/vim-dadbod-ui' },
  { src = gh 'kristijanhusak/vim-dadbod-completion' },
  -- AI assistant
  { src = gh 'olimorris/codecompanion.nvim' },
}

-- ── Linting ────────────────────────────────────────────────────────────────
-- kickstart already ships a working nvim-lint module (lua/kickstart/plugins/
-- lint.lua) with the autocmd wired up; it is just not required from init.lua.
-- Requiring it here is the whole setup — then extend its table rather than
-- replacing it, so a kickstart update that adds a linter is not silently undone.
--
-- Every linter named here is a binary install_deps installs. A linter whose
-- binary is missing is not a no-op in nvim-lint: it reports the failed spawn on
-- every write, so the list is filtered by what is actually on PATH.
try('nvim-lint', function()
  require 'kickstart.plugins.lint'
  local lint = require 'lint'
  local by_ft = lint.linters_by_ft or {}

  if exe 'shellcheck' then
    by_ft.sh = { 'shellcheck' }
    by_ft.bash = { 'shellcheck' }
  end
  -- markdownlint-cli2 is the maintained CLI; kickstart's default names the old
  -- `markdownlint`, which is not what install_deps installs.
  if exe 'markdownlint-cli2' then
    by_ft.markdown = { 'markdownlint-cli2' }
  elseif not exe 'markdownlint' then
    by_ft.markdown = nil
  end

  lint.linters_by_ft = by_ft
end)

-- ── Debugger ───────────────────────────────────────────────────────────────
try('nvim-dap', function()
  local dap, dapui = require 'dap', require 'dapui'

  dapui.setup {
    icons = vim.g.have_nerd_font == true and {} or
      { expanded = 'v', collapsed = '>', current_frame = '*' },
    controls = { enabled = false }, -- the control bar needs a Nerd Font to read
  }

  -- gdb speaks DAP itself since gdb 14 — `gdb -i dap` IS the adapter. This is
  -- why there is no Mason package, no codelldb tarball and no rust toolchain
  -- anywhere in this setup.
  if exe 'gdb' then
    dap.adapters.gdb = {
      type = 'executable',
      command = 'gdb',
      args = { '--interpreter=dap', '--eval-command', 'set print pretty on' },
    }
    local gdb_config = {
      {
        name = 'Launch (gdb)',
        type = 'gdb',
        request = 'launch',
        -- Ask rather than guess: this VM builds a.out, libft.a and whatever the
        -- current exercise is, and there is no single right default.
        program = function()
          return vim.fn.input('Executable: ', vim.fn.getcwd() .. '/', 'file')
        end,
        cwd = '${workspaceFolder}',
        stopAtBeginningOfMainSubprogram = false,
      },
    }
    dap.configurations.c = gdb_config
    dap.configurations.cpp = gdb_config
  end

  -- debugpy lives in the venv install_nvim.sh built, because Debian's system
  -- python3 is PEP 668 externally-managed and cannot take a pip install.
  local venv_python = VENV .. '/bin/python3'
  if vim.fn.executable(venv_python) == 1 then
    dap.adapters.python = {
      type = 'executable',
      command = venv_python,
      args = { '-m', 'debugpy.adapter' },
    }
    dap.configurations.python = {
      {
        name = 'Launch this file',
        type = 'python',
        request = 'launch',
        program = '${file}',
        cwd = '${workspaceFolder}',
        -- Prefer a project virtualenv when there is one, and fall back to the
        -- interpreter that is running the adapter.
        pythonPath = function()
          local local_venv = vim.fn.getcwd() .. '/.venv/bin/python'
          return vim.fn.executable(local_venv) == 1 and local_venv or venv_python
        end,
      },
    }
  end

  -- Open the UI when a session starts and close it when it ends, so the panes
  -- are never left behind over an ordinary editing buffer.
  dap.listeners.after.event_initialized['b2b'] = function() dapui.open() end
  dap.listeners.before.event_terminated['b2b'] = function() dapui.close() end
  dap.listeners.before.event_exited['b2b'] = function() dapui.close() end

  -- F-keys match every other debugger; the <leader>d prefix is the discoverable
  -- half. NOTE the deliberate difference from kickstart's own debug.lua, which
  -- binds bare <leader>b for a breakpoint: that would make barbar's <leader>bb
  -- and <leader>bo wait a full 'timeoutlen' on every press.
  map('<F5>', function() require('dap').continue() end, 'Debug: start/continue')
  map('<F9>', function() require('dap').toggle_breakpoint() end, 'Debug: toggle breakpoint')
  map('<F10>', function() require('dap').step_over() end, 'Debug: step over')
  map('<F11>', function() require('dap').step_into() end, 'Debug: step into')
  map('<F12>', function() require('dap').step_out() end, 'Debug: step out')
  map('<leader>dc', function() require('dap').continue() end, '[D]ebug: [c]ontinue')
  map('<leader>db', function() require('dap').toggle_breakpoint() end, '[D]ebug: toggle [b]reakpoint')
  map('<leader>dB', function()
    vim.ui.input({ prompt = 'Breakpoint condition: ' }, function(cond)
      if cond then require('dap').set_breakpoint(cond) end
    end)
  end, '[D]ebug: conditional [B]reakpoint')
  map('<leader>du', function() require('dapui').toggle() end, '[D]ebug: toggle [u]I')
  map('<leader>dr', function() require('dap').repl.toggle() end, '[D]ebug: [r]EPL')
  map('<leader>dt', function() require('dap').terminate() end, '[D]ebug: [t]erminate')
end)

-- ── Test runner ────────────────────────────────────────────────────────────
-- neotest is a framework, not a test runner: without an adapter it loads and
-- finds nothing, which looks exactly like a broken install. Only the python
-- adapter is shipped, because it is the only one of the language sets on this
-- VM (C, shell, PHP, python) with a maintained neotest adapter that needs no
-- extra runtime. Add more by extending the adapters list.
try('neotest', function()
  local adapters = {}
  local ok, python = pcall(require, 'neotest-python')
  if ok then table.insert(adapters, python { dap = { justMyCode = false } }) end
  require('neotest').setup { adapters = adapters }

  map('<leader>rt', function() require('neotest').run.run() end, '[R]un nearest [t]est')
  map('<leader>rf', function() require('neotest').run.run(vim.fn.expand '%') end, '[R]un tests in [f]ile')
  map('<leader>rl', function() require('neotest').run.run_last() end, '[R]un [l]ast test')
  map('<leader>rs', function() require('neotest').summary.toggle() end, '[R]un: [s]ummary panel')
  map('<leader>ro', function() require('neotest').output_panel.toggle() end, '[R]un: [o]utput panel')
  map('<leader>rd', function() require('neotest').run.run { strategy = 'dap' } end, '[R]un nearest under [d]ebugger')
end)

-- ── Terminal, and lazygit inside it ────────────────────────────────────────
try('toggleterm', function()
  require('toggleterm').setup {
    open_mapping = [[<c-\>]],
    direction = 'horizontal',
    size = 15,
    shade_terminals = true,
    start_in_insert = true,
    persist_size = true,
    -- Close the window when the shell exits, instead of leaving a dead buffer.
    close_on_exit = true,
  }

  -- <Esc> in a terminal must reach the program, not Neovim -- otherwise lazygit,
  -- htop and every TUI become unusable inside the terminal window. So terminal
  -- mode keeps <Esc>, and window navigation gets explicit bindings instead.
  vim.api.nvim_create_autocmd('TermOpen', {
    group = vim.api.nvim_create_augroup('b2b-term', { clear = true }),
    pattern = 'term://*toggleterm#*',
    callback = function(ev)
      local o = { buffer = ev.buf, silent = true, noremap = true }
      vim.keymap.set('t', '<C-h>', [[<Cmd>wincmd h<CR>]], o)
      vim.keymap.set('t', '<C-j>', [[<Cmd>wincmd j<CR>]], o)
      vim.keymap.set('t', '<C-k>', [[<Cmd>wincmd k<CR>]], o)
      vim.keymap.set('t', '<C-l>', [[<Cmd>wincmd l<CR>]], o)
    end,
  })

  map('<leader>tt', '<cmd>ToggleTerm<CR>', '[T]oggle [t]erminal')
  map('<leader>tF', '<cmd>ToggleTerm direction=float<CR>', '[T]erminal, [F]loating')

  -- lazygit. A dedicated Terminal object rather than the lazygit.nvim plugin:
  -- toggleterm is already installed and this is the four lines that plugin
  -- would have added.
  if exe 'lazygit' then
    local Terminal = require('toggleterm.terminal').Terminal
    local lazygit = Terminal:new {
      cmd = 'lazygit',
      hidden = true,
      direction = 'float',
      float_opts = { border = 'rounded' },
    }
    map('<leader>gg', function() lazygit:toggle() end, '[G]it: lazy[g]it')
  end
end)

-- ── Symbol outline ─────────────────────────────────────────────────────────
try('aerial', function()
  require('aerial').setup {
    backends = { 'lsp', 'treesitter', 'markdown', 'man' },
    layout = { min_width = 28 },
    attach_mode = 'global',
    show_guides = true,
    -- Do not hijack the start page or the file tree.
    ignore = { filetypes = { 'b2bstart', 'neo-tree', 'oil' } },
  }
  map('<leader>o', '<cmd>AerialToggle!<CR>', 'Symbol [o]utline')
  map('<leader>O', '<cmd>AerialNavToggle<CR>', 'Symbol [O]utline: floating nav')
end)

-- ── Breadcrumbs ────────────────────────────────────────────────────────────
-- navic in the winbar, but ONLY in windows whose buffer has an LSP that can
-- answer documentSymbol. Setting vim.o.winbar globally -- the line the README
-- gives -- puts an empty bar above the file tree, the start page and every
-- terminal, which costs a screen line each and shows nothing.
try('nvim-navic', function()
  local navic = require 'nvim-navic'
  navic.setup { highlight = true, separator = ' > ', depth_limit = 5 }

  local group = vim.api.nvim_create_augroup('b2b-navic', { clear = true })
  vim.api.nvim_create_autocmd('LspAttach', {
    group = group,
    callback = function(ev)
      local client = vim.lsp.get_client_by_id(ev.data.client_id)
      -- Attaching a client that cannot answer documentSymbol makes navic throw
      -- on every cursor move.
      if not client or not client:supports_method 'textDocument/documentSymbol' then return end
      navic.attach(client, ev.buf)
    end,
  })

  -- winbar is window-local, so it is set per window rather than once globally.
  vim.api.nvim_create_autocmd({ 'BufWinEnter', 'WinEnter' }, {
    group = group,
    callback = function()
      if vim.bo.buftype ~= '' then return end
      if navic.is_available(0) then
        vim.wo.winbar = "%{%v:lua.require'nvim-navic'.get_location()%}"
      end
    end,
  })
end)

-- ── Project root ───────────────────────────────────────────────────────────
-- What project.nvim is actually wanted for, in stdlib. `vim.fs.root` walks up
-- from the current file looking for any of these markers and returns the first
-- directory that has one; it has been in Neovim since 0.10.
--
-- It only ever cds when the file is INSIDE a project, and it uses :tcd, so
-- opening a file from somewhere else in a different tab does not move the
-- working directory out from under a session, a terminal or a running test.
do
  local MARKERS = { '.git', 'Makefile', 'package.json', 'pyproject.toml', 'Cargo.toml', 'composer.json' }
  local group = vim.api.nvim_create_augroup('b2b-project-root', { clear = true })
  vim.api.nvim_create_autocmd('BufEnter', {
    group = group,
    callback = function(ev)
      if vim.bo[ev.buf].buftype ~= '' then return end
      local name = vim.api.nvim_buf_get_name(ev.buf)
      if name == '' or name:match '^%w+://' then return end
      local root = vim.fs.root(ev.buf, MARKERS)
      if root and root ~= vim.fn.getcwd() then
        pcall(vim.cmd.tcd, vim.fn.fnameescape(root))
      end
    end,
  })
  vim.api.nvim_create_user_command('B2BRoot', function()
    vim.notify('project root: ' .. (vim.fs.root(0, MARKERS) or '(none — cwd is ' .. vim.fn.getcwd() .. ')'))
  end, { desc = 'Show the detected project root' })
end

-- ── REST client ────────────────────────────────────────────────────────────
-- Write a .http file, put the cursor in a request, press <leader>ks. kulala
-- drives `curl` and renders the response in a split.
--
-- kulala parses .http files with its OWN treesitter grammar (kulala_http, from
-- mistweaverco/tree-sitter-kulala-http), not the generic `http` one, and it
-- manages that grammar itself: on setup it git-fetches the repo and shells out
-- to `tree-sitter build`. Two consequences worth knowing about:
--
--   * That work is moved to build time by install_kulala_parser() in the
--     installer, so the user's first `nvim` is not a silent network fetch and
--     a compile. Same reasoning as the blink.cmp and markdown-preview binaries.
--   * With no `tree-sitter` CLI on PATH the build does not fail politely — it
--     raises ENOENT from inside a scheduled callback, which escapes as a raw
--     stack traceback over whatever you were doing. Verified on a box without
--     the CLI. So its own parser handling is enabled only when the CLI exists.
--
-- Everything else is left at its defaults on purpose: display_mode = 'split'
-- and default_view = 'body' are already the defaults, and they live under `ui`,
-- not at the top level, so setting them there does nothing at all.
try('kulala', function()
  require('kulala').setup { treesitter = { enable = exe 'tree-sitter' } }
  map('<leader>ks', function() require('kulala').run() end, '[K]ulala: [s]end request')
  map('<leader>ka', function() require('kulala').run_all() end, '[K]ulala: send [a]ll')
  map('<leader>kt', function() require('kulala').toggle_view() end, '[K]ulala: [t]oggle body/headers')
  map('<leader>kc', function() require('kulala').copy() end, '[K]ulala: [c]opy as curl')
end)

-- ── SQL client ─────────────────────────────────────────────────────────────
-- This VM runs MariaDB for WordPress, so a SQL client earns its place. No
-- connection string is baked in on purpose: it would be a database password in
-- a world-readable file under $HOME. Add one per machine instead, either in
-- ~/.local/share/db_ui (dadbod-ui writes it for you from `:DBUIAddConnection`)
-- or by exporting it, e.g.
--     export DBUI_URL='mysql://wpuser@localhost/wordpress'
do
  vim.g.db_ui_use_nerd_fonts = vim.g.have_nerd_font == true and 1 or 0
  vim.g.db_ui_save_location = vim.fn.stdpath 'data' .. '/db_ui'
  vim.g.db_ui_show_database_icon = 0
  vim.g.db_ui_win_position = 'left'
  vim.g.db_ui_winwidth = 32

  try('dadbod', function()
    if vim.fn.exists ':DBUI' ~= 2 then error 'vim-dadbod-ui did not load' end
    map('<leader>D', '<cmd>DBUIToggle<CR>', '[D]atabase UI')

    -- vim-dadbod-completion registers an omnifunc. Wiring it into blink.cmp as
    -- a source needs a compatibility shim; the omnifunc is native, works with
    -- <C-x><C-o>, and blink offers it through its own omni fallback.
    vim.api.nvim_create_autocmd('FileType', {
      group = vim.api.nvim_create_augroup('b2b-dadbod', { clear = true }),
      pattern = { 'sql', 'mysql', 'plsql' },
      callback = function() vim.bo.omnifunc = 'vim_dadbod_completion#omni' end,
    })
  end)
end

-- ── AI assistant ───────────────────────────────────────────────────────────
-- codecompanion needs a backend, and this VM may have none. Rather than leave
-- the default (copilot, which needs a browser login this box cannot do), the
-- adapter is chosen from what is actually reachable:
--
--   1. a local or host Ollama, which setup/install/ai/install_ai.sh sets up
--      and advertises through $OLLAMA_HOST;
--   2. Anthropic or OpenAI, when the matching key is exported;
--   3. nothing — the plugin is installed but the keymaps say so instead of
--      failing with an authentication error three menus deep.
try('codecompanion', function()
  local adapter
  if vim.env.OLLAMA_HOST or exe 'ollama' then
    adapter = 'ollama'
  elseif vim.env.ANTHROPIC_API_KEY then
    adapter = 'anthropic'
  elseif vim.env.OPENAI_API_KEY then
    adapter = 'openai'
  end

  if not adapter then
    local function no_backend()
      vim.notify(table.concat({
        'No AI backend is configured on this VM.',
        '',
        'Either install one:   sudo AI_MODE=local  setup/install/ai/install_ai.sh',
        'point at the host:    sudo AI_MODE=client setup/install/ai/install_ai.sh',
        'or export a key:      export ANTHROPIC_API_KEY=...  (then restart nvim)',
      }, '\n'), vim.log.levels.WARN)
    end
    map('<leader>aa', no_backend, '[A]I: not configured')
    map('<leader>ac', no_backend, '[A]I: not configured')
    return
  end

  require('codecompanion').setup {
    strategies = {
      chat = { adapter = adapter },
      inline = { adapter = adapter },
    },
  }
  map('<leader>aa', '<cmd>CodeCompanionActions<CR>', '[A]I: [a]ctions')
  map('<leader>ac', '<cmd>CodeCompanionChat Toggle<CR>', '[A]I: [c]hat')
  vim.keymap.set('v', '<leader>aa', '<cmd>CodeCompanionActions<CR>',
    { desc = '[A]I: [a]ctions on selection', silent = true, noremap = true })
end)
LUAEOF
	chmod 644 "${cfg}/plugin/60-b2b-ide.lua"
}

# ── Terminal fixes these bindings depend on ─────────────────────────────────
write_profile() {
	# Ctrl+S is swallowed by the tty as XOFF (software flow control) long before
	# Neovim sees it, which is why <C-s> "does nothing" in every terminal editor
	# until this is turned off. Ctrl+Q (XON) unfreezes a terminal that got stuck
	# the old way; nothing modern relies on either.
	cat > /etc/profile.d/nvim-extras.sh <<'PROFEOF'
# Added by born2root setup/install/nvim/install_nvim_extras.sh
#
# Free Ctrl+S (and Ctrl+Q) from terminal flow control so Neovim can bind them.
# Interactive terminals only: running stty against a pipe breaks scp, rsync and
# every other non-interactive SSH command.
case $- in
	*i*)
		[ -t 0 ] && stty -ixon 2>/dev/null
		;;
esac

# Where `vw` and Neovim keep saved sessions.
export NVIM_SESSION_DIR="${NVIM_SESSION_DIR:-$HOME/.nvim-sessions}"
PROFEOF
	chmod 644 /etc/profile.d/nvim-extras.sh
	log "wrote /etc/profile.d/nvim-extras.sh (frees Ctrl+S, sets NVIM_SESSION_DIR)"
}

# ── tmux: the half that makes remote sessions resumable ─────────────────────
# The workflow the extras are built around is "everything runs inside tmux on
# the VM": SSH in, attach, and the editor is exactly as you left it — including
# after the laptop lid closes, which is what kills a bare SSH session.
# b2b-setup.sh already installs tmux and writes a config; this only adds the
# pieces Neovim specifically needs, and only if they are not already there.
configure_tmux() {
	local user="$1" home conf
	home=$(getent passwd "$user" | cut -d: -f6)
	conf="${home}/.tmux.conf"
	local group; group=$(id -gn "$user" 2>/dev/null || echo "$user")

	[ -f "$conf" ] || : > "$conf"
	if grep -q 'born2root: neovim' "$conf" 2>/dev/null; then
		log "${user}: .tmux.conf already carries the Neovim block — leaving it"
		return 0
	fi

	cat >> "$conf" <<'TMUXEOF'

# ── born2root: neovim ───────────────────────────────────────────────────────
# True colour. Without this Neovim colourschemes render in 16 colours inside
# tmux and every theme looks wrong; `tmux info | grep Tc` verifies it.
set -g default-terminal "tmux-256color"
set -ga terminal-overrides ",*256col*:Tc,xterm-256color:Tc"

# Neovim's :checkhealth complains about the default 500ms: tmux waits that long
# after an Escape to see whether it is the start of an escape sequence, which
# shows up as a laggy exit from insert mode.
set -sg escape-time 10

# Long enough that a scrollback is actually useful, and focus events so
# Neovim's autoread notices files changed by another pane.
set -g history-limit 50000
set -g focus-events on

# Keep the pane's title in the terminal title bar, so a detached session is
# identifiable at a glance.
set -g set-titles on
set -g set-titles-string '#S:#I.#P #W'
TMUXEOF
	chown "${user}:${group}" "$conf" 2>/dev/null || true
	log "${user}: appended the Neovim block to ~/.tmux.conf"
}

# ── Per-user install ────────────────────────────────────────────────────────
setup_user() {
	local user="$1" home cfg group sessdir
	home=$(getent passwd "$user" 2>/dev/null | cut -d: -f6)
	if [ -z "$home" ] || [ ! -d "$home" ]; then
		warn "user '${user}' has no home directory — skipping"
		return 1
	fi
	cfg="${home}/.config/nvim"
	if [ ! -f "${cfg}/init.lua" ]; then
		warn "${user}: no kickstart config at ${cfg} — run install_nvim.sh first"
		return 1
	fi
	group=$(id -gn "$user" 2>/dev/null || echo "$user")
	sessdir="${home}/${NVIM_SESSION_DIR_NAME}"

	write_pack_lua "$cfg"
	write_plugins_lua "$cfg"
	write_keymaps_lua "$cfg"
	write_sessions_lua "$cfg" "$sessdir"
	write_startup_lua "$cfg"
	write_markdown_lua "$cfg" "$NVIM_MKDP_PORT"
	write_ide_lua "$cfg" "$NVIM_PYTHON_VENV"

	mkdir -p "$sessdir"

	# Keep the drop-ins out of `git status` in the kickstart checkout.
	if [ -d "${cfg}/.git" ]; then
		mkdir -p "${cfg}/.git/info"
		local f
		for f in plugin/05-b2b-pack.lua plugin/10-b2b-plugins.lua \
			plugin/20-b2b-keymaps.lua plugin/30-b2b-sessions.lua \
			plugin/40-b2b-startup.lua plugin/50-b2b-markdown.lua \
			plugin/60-b2b-ide.lua; do
			grep -qxF "$f" "${cfg}/.git/info/exclude" 2>/dev/null \
				|| printf '%s\n' "$f" >> "${cfg}/.git/info/exclude"
		done
	fi

	chown -R "${user}:${group}" "$cfg" "$sessdir" 2>/dev/null || true
	configure_tmux "$user"
	log "${user}: config layer written into ${cfg}/plugin/"
	return 0
}

# Run a command as <user>, with a terminal type Neovim can work with.
#
# TERM matters more than it looks. A non-interactive SSH session -- which is
# exactly how the host provisioner and @reboot cron both get here -- leaves
# TERM=dumb, and several of Neovim's own health checks shell out to terminfo:
# `:checkhealth` then reports
#     ERROR command failed: { "infocmp", "-L" }
# and a couple of plugin checks come back empty, so the saved report is full of
# failures that do not exist in the terminal the user actually opens. Verified:
# the same report run with TERM=xterm-256color has zero errors.
run_as_user() {
	local user="$1"; shift
	set -- env "TERM=${NVIM_TERM:-xterm-256color}" "$@"
	if [ "$user" = "root" ]; then timeout "$NVIM_BOOTSTRAP_TIMEOUT" "$@"
	else timeout "$NVIM_BOOTSTRAP_TIMEOUT" runuser -u "$user" -- "$@"; fi
}

# blink.cmp (kickstart's completion engine) does its matching in a small Rust
# library, shipped as a prebuilt binary per release. Without it blink silently
# falls back to a slower Lua matcher and :checkhealth warns
#     blink_cmp_fuzzy lib is not downloaded/built
#
# blink can fetch this itself, but only asynchronously: its download returns a
# task driven by the event loop, and a headless Neovim exits before the task
# resolves -- verified, the callback never fires and no file appears. Rather
# than try to pump the loop from a script, the same two files are fetched here
# with curl, into the exact paths blink's own health check looks at
# (<plugin>/target/release/). Deterministic, and it fails loudly.
install_blink_fuzzy() {
	local user="$1" home plugin tag triple lib_dir base
	home=$(getent passwd "$user" | cut -d: -f6)
	plugin="${home}/.local/share/nvim/site/pack/core/opt/blink.cmp"
	[ -d "$plugin" ] || { log "${user}: blink.cmp not installed — skipping its fuzzy lib"; return 0; }

	lib_dir="${plugin}/target/release"
	if [ -f "${lib_dir}/libblink_cmp_fuzzy.so" ]; then
		log "${user}: blink.cmp fuzzy lib already present"
		return 0
	fi

	# The binary must match the checked-out tag, so read it from the checkout
	# rather than assuming the newest release.
	#
	# Read it AS THE OWNING USER. This function runs as root while the plugin
	# tree belongs to $user, and git >= 2.35 refuses to operate on a repository
	# owned by somebody else ("detected dubious ownership") -- it exits non-zero
	# and prints nothing, so as root every one of these commands came back empty
	# and the lib was silently skipped with "cannot determine the tag". Verified:
	# the identical command run as the user returns v1.10.2.
	local git_as="runuser -u ${user} --"
	[ "$user" = "root" ] && git_as=""
	tag=$($git_as git -C "$plugin" describe --tags --exact-match 2>/dev/null) \
		|| tag=$($git_as git -C "$plugin" tag --points-at HEAD 2>/dev/null | head -n1)
	[ -n "$tag" ] || tag=$($git_as git -C "$plugin" describe --tags 2>/dev/null \
		| sed 's/-[0-9]*-g[0-9a-f]*$//')
	if [ -z "$tag" ]; then
		warn "${user}: cannot determine the blink.cmp tag — skipping its fuzzy lib"
		return 0
	fi

	case "$(uname -m)" in
		x86_64|amd64) triple="x86_64-unknown-linux-gnu" ;;
		aarch64|arm64) triple="aarch64-unknown-linux-gnu" ;;
		*) log "${user}: no prebuilt blink.cmp lib for $(uname -m) — Lua fallback stays"; return 0 ;;
	esac

	log "${user}: fetching the blink.cmp fuzzy library (${tag}, ${triple})"
	base="https://github.com/saghen/blink.cmp/releases/download/${tag}"
	mkdir -p "$lib_dir"

	if ! curl -fsSL --retry 3 --max-time 180 \
		-o "${lib_dir}/libblink_cmp_fuzzy.so.tmp" "${base}/${triple}.so"; then
		warn "${user}: could not download the blink.cmp fuzzy lib — the Lua fallback still works"
		rm -f "${lib_dir}/libblink_cmp_fuzzy.so.tmp"
		return 0
	fi
	# blink writes the checksum beside the library and reads it back later, so
	# fetch it too; verify while we have both.
	if curl -fsSL --retry 3 --max-time 60 \
		-o "${lib_dir}/libblink_cmp_fuzzy.so.sha256" "${base}/${triple}.so.sha256"; then
		local want got
		want=$(awk '{print $1; exit}' "${lib_dir}/libblink_cmp_fuzzy.so.sha256")
		got=$(sha256sum "${lib_dir}/libblink_cmp_fuzzy.so.tmp" | awk '{print $1}')
		if [ -n "$want" ] && [ "$want" != "$got" ]; then
			warn "${user}: blink.cmp fuzzy lib checksum mismatch — discarding it"
			rm -f "${lib_dir}/libblink_cmp_fuzzy.so.tmp" "${lib_dir}/libblink_cmp_fuzzy.so.sha256"
			return 0
		fi
	fi
	mv "${lib_dir}/libblink_cmp_fuzzy.so.tmp" "${lib_dir}/libblink_cmp_fuzzy.so"
	printf '%s\n' "$tag" > "${lib_dir}/version"

	local group; group=$(id -gn "$user" 2>/dev/null || echo "$user")
	chown -R "${user}:${group}" "${plugin}/target" 2>/dev/null || true
	log "${user}: blink.cmp fuzzy lib installed"
}

# markdown-preview.nvim ships its server as a prebuilt binary, NOT as part of
# the git checkout: `vim.pack.add` clones the plugin and you get a
# :MarkdownPreview that fails at press time with "Pre build not found".
#
# The plugin can fetch it itself (`:call mkdp#util#install()`), but that is a
# `jobstart` — asynchronous, driven by the event loop — and a headless Neovim
# exits before the job finishes. Exactly the same trap as blink.cmp's fuzzy
# library above, and the same answer: fetch it here with curl, into the exact
# path the plugin looks at, so the build either has a working preview or says
# out loud that it does not.
#
#   s:pre_build = <plugin>/app/bin/markdown-preview-  .  mkdp#util#get_platform()
#
# get_platform() returns 'linux' for everything that is not mac or windows, so
# the file has to be called markdown-preview-linux even on arm64 — and upstream
# publishes no arm64 build, which is why the arch check refuses rather than
# installing an x86_64 binary under a name that promises to work.
install_mkdp_binary() {
	local user="$1" home plugin bin_dir tag tmp
	home=$(getent passwd "$user" | cut -d: -f6)
	plugin="${home}/.local/share/nvim/site/pack/core/opt/markdown-preview.nvim"
	[ -d "$plugin" ] || { log "${user}: markdown-preview.nvim not installed — skipping its server"; return 0; }

	bin_dir="${plugin}/app/bin"
	if [ -x "${bin_dir}/markdown-preview-linux" ]; then
		log "${user}: markdown-preview server binary already present"
		return 0
	fi

	if [ "$(uname -m)" != "x86_64" ] && [ "$(uname -m)" != "amd64" ]; then
		warn "${user}: upstream publishes no markdown-preview binary for $(uname -m)"
		warn "${user}: build it in the VM with: cd ${plugin}/app && npx --yes yarn install"
		return 0
	fi

	tag=$(curl -fsSL --retry 3 --max-time 60 \
		https://api.github.com/repos/iamcco/markdown-preview.nvim/releases/latest 2>/dev/null \
		| sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
	# The repo has not been released since v0.0.10; pin to it when the API is
	# unreachable (rate-limited, or a NAT'd VM with no route) rather than giving up.
	[ -n "$tag" ] || { tag="v0.0.10"; log "${user}: GitHub API unreachable — pinning markdown-preview ${tag}"; }

	log "${user}: fetching the markdown-preview server binary (${tag})"
	tmp=$(mktemp -d) || { warn "${user}: mktemp failed"; return 0; }
	if ! curl -fsSL --retry 3 --max-time 300 -o "${tmp}/mp.tar.gz" \
		"https://github.com/iamcco/markdown-preview.nvim/releases/download/${tag}/markdown-preview-linux.tar.gz"; then
		warn "${user}: could not download the markdown-preview binary — :MarkdownPreview will not start"
		warn "${user}: retry from inside nvim with  :call mkdp#util#install()"
		rm -rf "$tmp"; return 0
	fi
	# A truncated download unpacks as a broken binary that fails at press time
	# with no useful message, so check the archive before trusting it.
	if ! gzip -t "${tmp}/mp.tar.gz" 2>/dev/null; then
		warn "${user}: the downloaded markdown-preview archive is not valid gzip (truncated?)"
		rm -rf "$tmp"; return 0
	fi

	mkdir -p "$bin_dir"
	if ! tar -xzf "${tmp}/mp.tar.gz" -C "$bin_dir"; then
		warn "${user}: could not unpack the markdown-preview binary"
		rm -rf "$tmp"; return 0
	fi
	rm -rf "$tmp"
	chmod 755 "${bin_dir}/markdown-preview-linux" 2>/dev/null || true

	local group; group=$(id -gn "$user" 2>/dev/null || echo "$user")
	chown -R "${user}:${group}" "${plugin}/app" 2>/dev/null || true

	if [ -x "${bin_dir}/markdown-preview-linux" ]; then
		log "${user}: markdown-preview server installed"
	else
		warn "${user}: markdown-preview binary is still missing after unpacking"
	fi
}

# kulala needs TWO things that are not in its git checkout, and fetches both on
# demand the first time you use it:
#
#   kulala-core   the executable that actually performs the requests, pulled
#                 from its own GitHub releases. Without it :checkhealth reports
#                 "kulala-core not found" and no request ever runs.
#   kulala_http   its own treesitter grammar, git-fetched and then compiled
#                 with the tree-sitter CLI.
#
# Left alone, both happen on the user's first interactive `nvim` — a download
# and a compile behind a progress spinner — and on a VM with no route they fail
# and retry on every start forever. So they are done here, at build time.
#
# Neither can be done with a plain headless start: both are driven by vim.system
# callbacks and Neovim exits before they resolve. vim.wait is what makes this
# work — it blocks while still pumping the event loop. Same trap, and the same
# shape of answer, as the blink.cmp fuzzy library and the markdown-preview binary.
install_kulala_runtime() {
	local user="$1" home plugin
	home=$(getent passwd "$user" | cut -d: -f6)
	plugin="${home}/.local/share/nvim/site/pack/core/opt/kulala.nvim"
	[ -d "$plugin" ] || { log "${user}: kulala.nvim not installed — skipping its runtime"; return 0; }

	if ! command -v tree-sitter >/dev/null 2>&1; then
		warn "${user}: no tree-sitter CLI on PATH — kulala's grammar cannot be built"
		warn "${user}: install_nvim.sh installs it (npm i -g tree-sitter-cli); .http files will not parse"
	fi

	log "${user}: fetching kulala-core and building its http grammar"
	run_as_user "$user" "$NVIM_BIN" --headless -c 'lua
		-- Every predicate is wrapped: these APIs throw when the thing they are
		-- asked about has never been installed, and an error inside vim.wait
		-- aborts the wait rather than returning false.
		local function settled(fn) return function() local ok, r = pcall(fn) return ok and r end end

		-- 300s each, not 600s. run_as_user wraps this whole invocation in
		-- `timeout $NVIM_BOOTSTRAP_TIMEOUT` (1200s), and two 600s waits add up
		-- to exactly that -- so a slow network would get the process killed
		-- mid-download with no message rather than reporting what failed.
		local WAIT = 300000

		local ok_b, backend = pcall(require, "kulala.backend")
		if ok_b then
			pcall(backend.ensure_installed, function() end)
			print(vim.wait(WAIT, settled(backend.is_up_to_date), 1000)
				and "kulala-core ready" or "kulala-core NOT ready (network?)")
		else
			print("kulala.backend not available")
		end

		local ok_p, parser = pcall(require, "kulala.config.parser")
		if ok_p then
			-- 60-b2b-ide.lua already called kulala.setup() during startup, which
			-- kicks the grammar fetch off; this only waits for it to land.
			print(vim.wait(WAIT, settled(parser.is_up_to_date), 1000)
				and "kulala grammar ready" or "kulala grammar NOT ready (no CLI, or network?)")
		else
			print("kulala.config.parser not available")
		end
	' -c 'qa' 2>&1 | sed 's/^/[nvim-extras]   /' || warn "${user}: kulala runtime setup returned non-zero"

	local group; group=$(id -gn "$user" 2>/dev/null || echo "$user")
	chown -R "${user}:${group}" "${home}/.local/share/nvim" 2>/dev/null || true
}

bootstrap_user() {
	local user="$1" home group
	home=$(getent passwd "$user" | cut -d: -f6)
	group=$(id -gn "$user" 2>/dev/null || echo "$user")

	log "${user}: downloading the extra plugins (a few minutes on a cold cache)"
	local i
	for i in 1 2; do
		run_as_user "$user" "$NVIM_BIN" --headless +'lua vim.cmd("sleep 300m")' +qa >/dev/null 2>&1 \
			|| warn "${user}: headless start ${i} returned non-zero"
	done

	log "${user}: refreshing treesitter parsers"
	run_as_user "$user" "$NVIM_BIN" --headless +'silent! TSUpdateSync' +qa >/dev/null 2>&1 || true

	# Mason installs the language servers and formatters kickstart asks for
	# (lua-language-server, stylua). Nothing else triggers this: the plain
	# headless starts above load mason-tool-installer but its install runs
	# asynchronously and the process exits first, so without the explicit
	# *Sync* command you end up with a config that has LSP wired up and no
	# language server behind it -- :checkhealth reports
	#     'lua-language-server' is not executable
	# and nothing works, with no obvious cause.
	log "${user}: installing Mason language servers + formatters"
	run_as_user "$user" "$NVIM_BIN" --headless \
		+'silent! MasonToolsUpdateSync' +qa >/dev/null 2>&1 \
		|| warn "${user}: MasonToolsUpdateSync returned non-zero"

	install_blink_fuzzy "$user"
	install_mkdp_binary "$user"
	install_kulala_runtime "$user"

	# What actually loaded. :B2BExtras writes to the message area, so it has to
	# be captured through :redir, and two things had to be got right:
	#  - each piece needs its own -c, because `redir` takes the whole rest of
	#    the line as its argument: `redir >> /dev/stdout | silent B2BExtras` is
	#    read as a redirect to a file named "/dev/stdout | silent B2BExtras"
	#    and fails with E488;
	#  - it cannot redirect to /dev/stdout at all, because under runuser stdout
	#    is a pipe, and Neovim refuses to open a pipe by name (E190).
	# So it writes a real file. That file lives in the user's own state
	# directory rather than /tmp: nvim runs as them and must be able to create
	# it, and a mode-666 file in a world-writable /tmp is a symlink race
	# waiting to be lost.
	log "${user}: verifying the extras"
	local report_file="${home}/.local/state/nvim/b2b-extras.log"
	run_as_user "$user" "$NVIM_BIN" --headless \
		-c "redir! > ${report_file}" -c 'silent B2BExtras' -c 'redir END' -c 'qa' >/dev/null 2>&1 || true
	if [ -s "$report_file" ]; then
		sed 's/^/[nvim-extras]   /' "$report_file"
	else
		warn "${user}: :B2BExtras produced no report"
	fi

	chown -R "${user}:${group}" "${home}/.local" "${home}/.cache" 2>/dev/null || true
}

health_report() {
	local user="$1" home out group
	home=$(getent passwd "$user" | cut -d: -f6)
	group=$(id -gn "$user" 2>/dev/null || echo "$user")
	out="${home}/.local/state/nvim/checkhealth.log"
	mkdir -p "$(dirname "$out")"

	run_as_user "$user" "$NVIM_BIN" --headless +'checkhealth' +"w! ${out}" +qa >/dev/null 2>&1 || true
	if [ -s "$out" ]; then
		chown "${user}:${group}" "$out" 2>/dev/null || true
		# Neovim writes these as "- ❌ ERROR ..." and "- ⚠️ WARNING ...", with the
		# emoji between the bullet and the word -- so an anchored '^- ERROR'
		# matches nothing at all and every report looks perfectly clean.
		local errs warns
		errs=$(grep -cE '^- .*\bERROR\b' "$out" 2>/dev/null || true); errs=${errs:-0}
		warns=$(grep -cE '^- .*\bWARNING\b' "$out" 2>/dev/null || true); warns=${warns:-0}
		log "${user}: checkhealth — ${errs} error(s), ${warns} warning(s) — full report: ${out}"
		[ "$errs" -gt 0 ] && grep -E '^- .*\bERROR\b' "$out" | sed 's/^/[nvim-extras]   /' | head -n 20
	else
		warn "${user}: checkhealth produced no output"
	fi
	return 0
}

# ── main ────────────────────────────────────────────────────────────────────
log "=== Neovim extras (buffers, files, git, sessions, movement) ==="
install_deps
write_profile
write_vw "$NVIM_SESSION_DIR_NAME"

configured=""
for u in $NVIM_USERS; do
	setup_user "$u" && configured="${configured} ${u}"
done
[ -n "${configured// /}" ] || die "no users configured — nothing to do"

if [ "$NVIM_BOOTSTRAP" = "1" ]; then
	for u in $configured; do
		bootstrap_user "$u"
		health_report "$u"
	done
else
	log "NVIM_BOOTSTRAP=0 — config written, plugins not downloaded"
fi

log "=== done for:${configured} ==="
log "inside nvim:  :B2BExtras   what loaded    |  :B2BMarkdown  reach the preview"
log "              <leader>sS   start a session |  <leader>gg    lazygit"
log "in the shell: vw           list sessions   |  vw <name>     open one"
log "markdown preview: tunnel it from the host with"
log "  ssh -p 4242 -L ${NVIM_MKDP_PORT}:127.0.0.1:${NVIM_MKDP_PORT} <user>@127.0.0.1"
