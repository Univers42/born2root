#!/usr/bin/env hellish
#
# install_excalidraw.sh — a self-hosted Excalidraw editor for this VM's
# .excalidraw files, opened from Neovim, drawn in the host's browser.
#
# WHY
# ---
# VS Code has an Excalidraw extension: open a .excalidraw file, draw, it
# saves. Neovim has nothing of the kind, and Excalidraw is a React app, so it
# cannot run in a terminal. What CAN be done, and is done here, is the same
# thing the VS Code extension does under the hood: host the official
# @excalidraw/excalidraw component in a page, load the file into it, write
# the file back on every change. The page is served from the VM on
# 127.0.0.1:${EXCALIDRAW_PORT}, a port the build makes `ssh b2b` forward
# (setup/host/qemu_vm.sh ssh-config, generate/orchestrate.sh), so the URL
# Neovim prints opens in the host's browser -- the same arrangement as the
# markdown preview on 8420.
#
# Every save also writes <name>.excalidraw.svg beside the source, with the
# scene embedded (excalidraw.com re-opens such a file), so a drawing is one
# `![](name.excalidraw.svg)` away from rendering in the markdown preview and
# on GitHub.
#
# BUILT ONCE, HERE, AT BUILD TIME
# -------------------------------
# The component is an ES module with a dozen bare imports (react, roughjs,
# radix-ui, jotai, ...), so it needs a bundler. npm fetches
# @excalidraw/excalidraw, react and esbuild into a scratch directory on
# /var/tmp, esbuild produces the app in a few seconds, the scratch directory
# is deleted. The result is ~20 MB on /opt, with no CDN at runtime and no
# node_modules kept. A build that fails exits 1: first boot records
# nvim-extras as failed and `make all` says so, rather than shipping an
# :Excalidraw that 404s.
#
# Fonts: the component loads its typefaces from window.EXCALIDRAW_ASSET_PATH
# + "fonts/…", so dist/prod/fonts is copied beside the bundle and the page
# sets that path to "/". The locale bundles are static dynamic imports in the
# component's own build (a lookup table of import("./locales/xx-HASH.js")),
# which esbuild turns into chunks -- nothing to copy for them.
#
# WHAT LANDS WHERE
#   /opt/excalidraw/app/          index.html, app.js (+ chunks/), index.css, fonts/
#   /opt/excalidraw/server.js     static files + GET/PUT /api/file?path=… (node, no deps)
#   /usr/local/bin/excalidraw     `excalidraw diagram.excalidraw` from any shell
#   ~/.config/nvim/plugin/55-b2b-excalidraw.lua   :Excalidraw, <leader>me
#
# The server binds 127.0.0.1 only and reads/writes any *.excalidraw or
# *.excalidraw.svg path the user running it can, which is the same trust
# boundary as that user's shell: it exists to be driven by that user's
# Neovim, through that user's SSH session.
#
# USAGE
#   sudo ./install_excalidraw.sh                        # default: user dlesieur
#   sudo EXCALIDRAW_USERS="dlesieur root" ./install_excalidraw.sh
#   sudo EXCALIDRAW_VERSION=0.18.1 ./install_excalidraw.sh   # npm version (pinned by default)
#   sudo EXCALIDRAW_FORCE=1 ./install_excalidraw.sh           # rebuild an existing install

set -u

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PATH

# Pinned: a build that silently picks up a new major of a React component is
# not reproducible, and the page below is written against 0.18's API
# (index.css import, exportToSvg/serializeAsJSON exports, react 19 peer).
EXCALIDRAW_VERSION="${EXCALIDRAW_VERSION:-0.18.1}"
REACT_VERSION="${REACT_VERSION:-19.3.0}"
ESBUILD_VERSION="${ESBUILD_VERSION:-0.28.2}"
EXCALIDRAW_PORT="${EXCALIDRAW_PORT:-8421}"
EXCALIDRAW_DIR="${EXCALIDRAW_DIR:-/opt/excalidraw}"
EXCALIDRAW_USERS="${EXCALIDRAW_USERS:-dlesieur}"
EXCALIDRAW_FORCE="${EXCALIDRAW_FORCE:-0}"
EXCALIDRAW_BIN="${EXCALIDRAW_BIN:-/usr/local/bin/excalidraw}"

log() { printf '[excalidraw] %s\n' "$*"; }
warn() { printf '[excalidraw] WARN: %s\n' "$*" >&2; }
die() {
    printf '[excalidraw] ERROR: %s\n' "$*" >&2
    exit 1
}

[ "$(id -u)" -eq 0 ] || die "must run as root (use sudo)"
command -v node >/dev/null 2>&1 || die "node is required (install_nvim.sh installs it)"
command -v npm >/dev/null 2>&1 || die "npm is required (install_nvim.sh installs it)"
node_major=$(node -v 2>/dev/null | sed 's/^v\([0-9]*\).*/\1/')
if [ -z "$node_major" ] || [ "$node_major" -lt 18 ]; then
    die "node 18+ is required (have $(node -v 2>/dev/null))"
fi

# ── The page ────────────────────────────────────────────────────────────────
# One React component, one file: load it, draw, save it back. The only thing
# the VS Code extension has that this does not is a file picker, and Neovim is
# the file picker here.
write_app_source() {
    local src="$1"
    cat >"${src}/app.jsx" <<'JSXEOF'
// app.jsx — written by setup/install/nvim/install_excalidraw.sh, bundled by esbuild.
import React, { useCallback, useEffect, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { Excalidraw, exportToSvg, serializeAsJSON } from '@excalidraw/excalidraw';

const FILE = new URLSearchParams(location.search).get('file');
const SAVE_DELAY_MS = 800;

async function api(method, path, body) {
  const res = await fetch('/api/file?path=' + encodeURIComponent(path), {
    method,
    body,
    headers: body ? { 'Content-Type': 'application/octet-stream' } : undefined,
  });
  if (!res.ok && !(method === 'GET' && res.status === 404)) {
    throw new Error(method + ' ' + res.status + ': ' + (await res.text()));
  }
  return res;
}

function App() {
  const [initial, setInitial] = useState(null);
  const [status, setStatus] = useState(FILE ? 'loading…' : 'scratch pad — nothing is saved without ?file=');
  const timer = useRef(null);
  const lastJson = useRef(null);

  useEffect(() => {
    (async () => {
      if (!FILE) {
        setInitial({ elements: [], appState: {}, files: {} });
        return;
      }
      try {
        const res = await api('GET', FILE);
        if (res.status === 404) {
          setInitial({ elements: [], appState: {}, files: {} });
          setStatus('new file');
          return;
        }
        const scene = JSON.parse(await res.text());
        // A saved appState may carry keys the component refuses to be handed
        // back (collaborators must be a Map); keep only what a file should set.
        const { viewBackgroundColor, gridSize, gridModeEnabled } = scene.appState || {};
        setInitial({
          elements: scene.elements || [],
          appState: { viewBackgroundColor, gridSize, gridModeEnabled },
          files: scene.files || {},
          scrollToContent: true,
        });
        setStatus('loaded');
      } catch (e) {
        setStatus('error: ' + e.message);
      }
    })();
  }, []);

  // Debounced: onChange fires on every pointer move. serializeAsJSON keeps
  // only the persistent part of appState, so selection and scrolling do not
  // produce a "change" -- comparing the JSON is what makes autosave quiet.
  const onChange = useCallback((elements, appState, files) => {
    if (!FILE) return;
    clearTimeout(timer.current);
    timer.current = setTimeout(async () => {
      try {
        const json = serializeAsJSON(elements, appState, files, 'local');
        if (json === lastJson.current) return;
        await api('PUT', FILE, json);
        lastJson.current = json;
        const live = elements.filter((el) => !el.isDeleted);
        const svg = await exportToSvg({
          elements: live,
          appState: { ...appState, exportBackground: true, exportEmbedScene: true, exportWithDarkMode: false },
          files,
          exportPadding: 16,
        });
        await api('PUT', FILE + '.svg', new XMLSerializer().serializeToString(svg));
        setStatus('saved ' + new Date().toLocaleTimeString() + ' (' + live.length + ' elements, + .svg)');
      } catch (e) {
        setStatus('save failed: ' + e.message);
      }
    }, SAVE_DELAY_MS);
  }, []);

  return (
    <div style={{ height: '100vh', display: 'flex', flexDirection: 'column' }}>
      <div style={{ font: '12px system-ui, sans-serif', padding: '3px 10px', background: '#f3f3f3',
        borderBottom: '1px solid #ddd', display: 'flex', gap: 14, alignItems: 'baseline' }}>
        <span style={{ fontWeight: 600 }}>{FILE || 'Excalidraw'}</span>
        <span id="b2b-status" style={{ color: '#555' }}>{status}</span>
      </div>
      <div style={{ flex: 1, minHeight: 0 }}>
        {initial && (
          <Excalidraw initialData={initial} onChange={onChange}
            UIOptions={{ canvasActions: { loadScene: false, saveToActiveFile: false } }} />
        )}
      </div>
    </div>
  );
}

createRoot(document.getElementById('root')).render(<App />);
JSXEOF

    cat >"${src}/index.html" <<'HTMLEOF'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Excalidraw</title>
<!-- written by setup/install/nvim/install_excalidraw.sh -->
<link rel="stylesheet" href="/index.css">
<script>window.EXCALIDRAW_ASSET_PATH = '/';</script>
<style>html, body, #root { height: 100%; margin: 0; }</style>
</head>
<body>
<div id="root"></div>
<script type="module" src="/app.js"></script>
</body>
</html>
HTMLEOF
}

# ── The server ──────────────────────────────────────────────────────────────
# Node's http module and nothing else: static files from app/, and one JSON
# endpoint that reads and writes a file the caller names. Writes go through a
# temp file and rename, so a browser tab dying mid-PUT never leaves a
# half-written drawing, and a body that is not JSON is refused for the
# .excalidraw itself (the .svg beside it is opaque).
write_server() {
    cat >"${EXCALIDRAW_DIR}/server.js" <<'JSEOF'
#!/usr/bin/env node
// server.js — written by setup/install/nvim/install_excalidraw.sh.
//   node server.js [--port 8421] [--host 127.0.0.1]
// GET  /                          the editor (add ?file=/abs/path.excalidraw)
// GET  /api/file?path=…           the file's bytes (404 when it does not exist yet)
// PUT  /api/file?path=…           replace the file atomically
'use strict';
const http = require('http');
const fs = require('fs');
const path = require('path');

const APP = path.join(__dirname, 'app');
const TYPES = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.json': 'application/json', '.map': 'application/json',
  '.woff2': 'font/woff2', '.woff': 'font/woff', '.ttf': 'font/ttf',
  '.svg': 'image/svg+xml', '.png': 'image/png',
};
const MAX_BODY = 64 * 1024 * 1024;

function send(res, code, body, type) {
  res.writeHead(code, { 'Content-Type': type || 'text/plain; charset=utf-8', 'Cache-Control': 'no-store' });
  res.end(body);
}
function allowed(p) {
  return typeof p === 'string' && path.isAbsolute(p) && !p.includes('\0')
    && (p.endsWith('.excalidraw') || p.endsWith('.excalidraw.svg'));
}
function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > MAX_BODY) { reject(new Error('body too large')); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

async function handle(req, res) {
  const u = new URL(req.url, 'http://127.0.0.1');
  if (u.pathname === '/api/file') {
    const file = u.searchParams.get('path');
    if (!allowed(file)) return send(res, 400, 'path must be an absolute *.excalidraw or *.excalidraw.svg file');
    if (req.method === 'GET') {
      try {
        return send(res, 200, fs.readFileSync(file), file.endsWith('.svg') ? 'image/svg+xml' : 'application/json');
      } catch (e) {
        return send(res, e.code === 'ENOENT' ? 404 : 500, String(e.message));
      }
    }
    if (req.method === 'PUT') {
      try {
        const body = await readBody(req);
        if (file.endsWith('.excalidraw')) JSON.parse(body.toString('utf8'));
        const tmp = file + '.tmp-' + process.pid;
        fs.writeFileSync(tmp, body);
        fs.renameSync(tmp, file);
        return send(res, 204, '');
      } catch (e) {
        return send(res, 500, String(e.message));
      }
    }
    return send(res, 405, 'GET or PUT');
  }
  if (req.method !== 'GET' && req.method !== 'HEAD') return send(res, 405, 'GET only');
  let rel = decodeURIComponent(u.pathname);
  if (rel === '/') rel = '/index.html';
  const abs = path.normalize(path.join(APP, rel));
  if (!abs.startsWith(APP + path.sep)) return send(res, 403, 'forbidden');
  fs.readFile(abs, (err, data) => {
    if (err) return send(res, 404, 'not found: ' + rel);
    send(res, 200, data, TYPES[path.extname(abs)] || 'application/octet-stream');
  });
}

function start(port, host) {
  const server = http.createServer((req, res) => {
    handle(req, res).catch((e) => send(res, 500, String(e && e.message)));
  });
  server.listen(port, host);
  return server;
}

if (require.main === module) {
  let port = 8421;
  let host = '127.0.0.1';
  const args = process.argv.slice(2);
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--port') port = Number(args[++i]);
    else if (args[i] === '--host') host = args[++i];
  }
  const server = start(port, host);
  server.on('error', (e) => {
    if (e.code === 'EADDRINUSE') {
      console.error('excalidraw: ' + host + ':' + port + ' is already in use (a server is probably running)');
      process.exit(3);
    }
    console.error('excalidraw: ' + e.message);
    process.exit(1);
  });
  server.on('listening', () => console.log('excalidraw: http://' + host + ':' + port + '/  (add ?file=/absolute/path.excalidraw)'));
}

module.exports = { start, allowed };
JSEOF
    chmod 644 "${EXCALIDRAW_DIR}/server.js"
}

# ── The shell launcher ──────────────────────────────────────────────────────
# `excalidraw notes/arch.excalidraw` from any shell in the VM: creates the file
# when new, starts the server when nothing answers on the port, prints the URL.
write_launcher() {
    cat >"$EXCALIDRAW_BIN" <<LAUNCHEOF
#!/bin/sh
# excalidraw [file[.excalidraw]] — written by setup/install/nvim/install_excalidraw.sh
# Serves the born2root Excalidraw editor on 127.0.0.1:\${EXCALIDRAW_PORT:-${EXCALIDRAW_PORT}}
# and prints the URL for the given file. \`ssh b2b\` forwards the port, so the URL
# opens in the host's browser as printed.
PORT="\${EXCALIDRAW_PORT:-${EXCALIDRAW_PORT}}"
SERVER="${EXCALIDRAW_DIR}/server.js"
f="\${1:-}"
if [ -n "\$f" ]; then
    case "\$f" in *.excalidraw) ;; *) f="\$f.excalidraw" ;; esac
    case "\$f" in /*) ;; *) f="\$(pwd)/\$f" ;; esac
    if [ ! -f "\$f" ]; then
        printf '{"type":"excalidraw","version":2,"source":"born2root","elements":[],"appState":{"viewBackgroundColor":"#ffffff"},"files":{}}\\n' >"\$f" ||
            { echo "excalidraw: cannot create \$f" >&2; exit 1; }
    fi
fi
if ! node -e "require('net').connect(\$PORT,'127.0.0.1').on('connect',()=>process.exit(0)).on('error',()=>process.exit(1))" 2>/dev/null; then
    nohup node "\$SERVER" --port "\$PORT" >/dev/null 2>&1 &
    sleep 1
fi
url="http://127.0.0.1:\$PORT/"
if [ -n "\$f" ]; then
    url="\${url}?file=\$(printf '%s' "\$f" | node -e 'process.stdout.write(encodeURIComponent(require("fs").readFileSync(0,"utf8")))')"
fi
echo "\$url"
echo "(port \$PORT is forwarded by 'ssh b2b': open the URL in your host browser; saves land in \${f:-the file you open} and its .svg)"
LAUNCHEOF
    chmod 755 "$EXCALIDRAW_BIN"
}

# ── The Neovim side ─────────────────────────────────────────────────────────
# A plugin/ drop-in like the rest of the born2root layer (see
# install_nvim_extras.sh): it does not touch kickstart's checkout. :Excalidraw
# starts the server as a child of this Neovim when nothing answers on the
# port, so quitting Neovim takes the server with it, and prints the URL.
write_nvim_lua() {
    local cfg="$1"
    mkdir -p "${cfg}/plugin"
    cat >"${cfg}/plugin/55-b2b-excalidraw.lua" <<LUAHEAD
-- 55-b2b-excalidraw.lua — written by setup/install/nvim/install_excalidraw.sh
local PORT = ${EXCALIDRAW_PORT}
local SERVER = '${EXCALIDRAW_DIR}/server.js'
LUAHEAD
    cat >>"${cfg}/plugin/55-b2b-excalidraw.lua" <<'LUAEOF'

-- Excalidraw for .excalidraw files: the editor runs in the HOST's browser,
-- served from this VM (see the installer header for the whole arrangement).
--
--   :Excalidraw [file]   serve the editor for this buffer's file (or [file],
--                        created when new) and print its URL
--   <leader>me           the same for the current buffer
--
-- The page saves the .excalidraw on every change and an .excalidraw.svg
-- beside it; `![](name.excalidraw.svg)` embeds the drawing in markdown, where
-- the markdown preview (<leader>mp) renders it.

local EMPTY_SCENE = '{"type":"excalidraw","version":2,"source":"born2root","elements":[],'
  .. '"appState":{"viewBackgroundColor":"#ffffff"},"files":{}}'

-- .excalidraw files are JSON; highlight and fold them as such.
vim.filetype.add { extension = { excalidraw = 'json' } }

-- The browser writes the file behind Neovim's back; pick that up instead of
-- asking "file changed on disk" on the next write.
vim.api.nvim_create_autocmd({ 'FocusGained', 'BufEnter', 'CursorHold' }, {
  pattern = '*.excalidraw',
  callback = function() vim.cmd 'silent! checktime' end,
})

local function port_open(cb)
  local uv = vim.uv or vim.loop
  local sock = uv.new_tcp()
  sock:connect('127.0.0.1', PORT, function(err)
    sock:close()
    vim.schedule(function() cb(err == nil) end)
  end)
end

local server_job = nil
local function ensure_server(cb)
  port_open(function(up)
    if up then return cb(true) end
    if vim.fn.executable 'node' ~= 1 or vim.fn.filereadable(SERVER) ~= 1 then
      vim.notify(('excalidraw: node or %s is missing — re-run setup/install/nvim/install_excalidraw.sh'):format(SERVER),
        vim.log.levels.ERROR)
      return cb(false)
    end
    server_job = vim.fn.jobstart({ 'node', SERVER, '--port', tostring(PORT) }, { detach = false })
    if server_job <= 0 then
      vim.notify('excalidraw: could not start the server', vim.log.levels.ERROR)
      return cb(false)
    end
    local tries = 0
    local function poll()
      port_open(function(ok)
        if ok then return cb(true) end
        tries = tries + 1
        if tries > 30 then
          vim.notify(('excalidraw: the server did not come up on 127.0.0.1:%d'):format(PORT), vim.log.levels.ERROR)
          return cb(false)
        end
        vim.defer_fn(poll, 100)
      end)
    end
    poll()
  end)
end

local function urlencode(s)
  return (s:gsub('[^%w%-%._~/]', function(c) return ('%%%02X'):format(c:byte()) end))
end

local function open(arg)
  local path = (arg and arg ~= '') and vim.fn.fnamemodify(arg, ':p') or vim.api.nvim_buf_get_name(0)
  if path == '' then
    vim.notify('excalidraw: no file — :Excalidraw <name>.excalidraw', vim.log.levels.WARN)
    return
  end
  if not path:match '%.excalidraw$' then
    -- A markdown or code buffer: draw next to it, under its own name.
    path = vim.fn.fnamemodify(path, ':r') .. '.excalidraw'
  end
  if vim.fn.filereadable(path) == 0 then
    vim.fn.mkdir(vim.fn.fnamemodify(path, ':h'), 'p')
    if vim.fn.writefile({ EMPTY_SCENE }, path) ~= 0 then
      vim.notify('excalidraw: cannot create ' .. path, vim.log.levels.ERROR)
      return
    end
  end
  ensure_server(function(ok)
    if not ok then return end
    local url = ('http://127.0.0.1:%d/?file=%s'):format(PORT, urlencode(path))
    pcall(vim.fn.setreg, '+', url)
    vim.notify(table.concat({
      'Excalidraw: ' .. url,
      '',
      ('`ssh b2b` forwards port %d, so that URL opens in your host browser as it is.'):format(PORT),
      'Saves land in ' .. path .. ' and ' .. path .. '.svg',
      'The server stops when this Neovim quits; `excalidraw <file>` in a shell keeps one running.',
    }, '\n'), vim.log.levels.INFO)
  end)
end

vim.api.nvim_create_user_command('Excalidraw', function(o) open(o.args) end,
  { nargs = '?', complete = 'file', desc = 'Edit a .excalidraw file in the (host) browser' })
vim.keymap.set('n', '<leader>me', function() open() end,
  { desc = '[M]arkdown: [E]xcalidraw drawing for this file', silent = true })
LUAEOF
    chmod 644 "${cfg}/plugin/55-b2b-excalidraw.lua"
}

setup_user() {
    local user="$1" home cfg group
    home=$(getent passwd "$user" 2>/dev/null | cut -d: -f6)
    if [ -z "$home" ] || [ ! -d "$home" ]; then
        warn "user '${user}' has no home directory — skipping"
        return 1
    fi
    cfg="${home}/.config/nvim"
    if [ ! -f "${cfg}/init.lua" ]; then
        warn "${user}: no Neovim config at ${cfg} — run install_nvim.sh first; skipping the :Excalidraw command"
        return 1
    fi
    write_nvim_lua "$cfg"
    if [ -d "${cfg}/.git" ]; then
        mkdir -p "${cfg}/.git/info"
        grep -qxF "plugin/55-b2b-excalidraw.lua" "${cfg}/.git/info/exclude" 2>/dev/null ||
            printf '%s\n' "plugin/55-b2b-excalidraw.lua" >>"${cfg}/.git/info/exclude"
    fi
    group=$(id -gn "$user" 2>/dev/null || echo "$user")
    chown "${user}:${group}" "${cfg}/plugin/55-b2b-excalidraw.lua" 2>/dev/null || true
    log "${user}: :Excalidraw and <leader>me written to ${cfg}/plugin/55-b2b-excalidraw.lua"
}

# ── Build ───────────────────────────────────────────────────────────────────
installed_version() {
    sed -n 's/^excalidraw=//p' "${EXCALIDRAW_DIR}/app/VERSION" 2>/dev/null | head -n1
}

build_app() {
    local build
    # /var/tmp, not /tmp: node_modules for the build is ~100 MB and the /tmp
    # volume this layout makes is 0.4 GB at SIZE_B2B=15.
    build=$(mktemp -d /var/tmp/excalidraw-build.XXXXXX) || die "mktemp failed"

    log "fetching @excalidraw/excalidraw@${EXCALIDRAW_VERSION}, react@${REACT_VERSION}, esbuild@${ESBUILD_VERSION} (scratch: ${build})"
    # npm's cache would land in /root/.npm on /; keep it in the scratch dir so
    # it goes away with it. No lockfile, no audit, no funding banner.
    if ! (
        cd "$build" || exit 1
        export npm_config_cache="${build}/.npm" npm_config_update_notifier=false \
            npm_config_fund=false npm_config_audit=false npm_config_progress=false
        printf '{"name":"b2b-excalidraw","private":true,"type":"module"}\n' >package.json
        npm install --loglevel=error --no-package-lock \
            "@excalidraw/excalidraw@${EXCALIDRAW_VERSION}" \
            "react@${REACT_VERSION}" "react-dom@${REACT_VERSION}" \
            "esbuild@${ESBUILD_VERSION}"
    ); then
        warn "npm install failed (network? registry?)"
        rm -rf "$build"
        return 1
    fi

    mkdir -p "${build}/src" "${build}/out"
    write_app_source "${build}/src"

    log "bundling with esbuild"
    if ! (
        cd "$build" || exit 1
        ./node_modules/.bin/esbuild src/app.jsx --bundle --minify --format=esm --splitting \
            --jsx=automatic --target=es2020 --outdir=out --entry-names=app \
            --chunk-names='chunks/[name]-[hash]' \
            --define:process.env.NODE_ENV='"production"' --log-level=warning
    ); then
        warn "esbuild failed"
        rm -rf "$build"
        return 1
    fi
    cp "${build}/src/index.html" "${build}/out/index.html"
    cp "${build}/node_modules/@excalidraw/excalidraw/dist/prod/index.css" "${build}/out/index.css" ||
        warn "dist/prod/index.css not found — the editor will render unstyled"
    if [ -d "${build}/node_modules/@excalidraw/excalidraw/dist/prod/fonts" ]; then
        cp -r "${build}/node_modules/@excalidraw/excalidraw/dist/prod/fonts" "${build}/out/fonts"
    else
        warn "dist/prod/fonts not found — the editor will use fallback fonts"
    fi
    printf 'excalidraw=%s\nreact=%s\nesbuild=%s\nbuilt=%s\n' \
        "$EXCALIDRAW_VERSION" "$REACT_VERSION" "$ESBUILD_VERSION" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${build}/out/VERSION"

    # Into place atomically: a failure above never leaves a half-built app
    # where a working one was.
    mkdir -p "$EXCALIDRAW_DIR"
    rm -rf "${EXCALIDRAW_DIR}/app.new"
    mv "${build}/out" "${EXCALIDRAW_DIR}/app.new" || {
        warn "could not stage ${EXCALIDRAW_DIR}/app.new"
        rm -rf "$build"
        return 1
    }
    rm -rf "${EXCALIDRAW_DIR}/app"
    mv "${EXCALIDRAW_DIR}/app.new" "${EXCALIDRAW_DIR}/app"
    rm -rf "$build"
    chmod -R a+rX "$EXCALIDRAW_DIR"
    log "built ${EXCALIDRAW_DIR}/app ($(du -sm "${EXCALIDRAW_DIR}/app" | cut -f1) MB)"
}

# ── Verify ──────────────────────────────────────────────────────────────────
# Not "the files exist": the server is started on an ephemeral port, the page
# is fetched, a scratch drawing is read and written through the API, and the
# server is stopped -- all inside one node process, so nothing is left running.
verify() {
    local f
    for f in app/index.html app/app.js app/index.css server.js; do
        [ -s "${EXCALIDRAW_DIR}/${f}" ] || {
            warn "missing or empty: ${EXCALIDRAW_DIR}/${f}"
            return 1
        }
    done
    [ -d "${EXCALIDRAW_DIR}/app/fonts" ] || warn "no fonts directory — the editor will use fallback fonts"
    node --check "${EXCALIDRAW_DIR}/server.js" || {
        warn "server.js does not parse"
        return 1
    }
    if ! node - "${EXCALIDRAW_DIR}/server.js" <<'SMOKEEOF'; then
const { start } = require(process.argv[2]);
const fs = require('fs');
const os = require('os');
const path = require('path');
const scratch = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'b2b-excalidraw-')), 'smoke.excalidraw');
const server = start(0, '127.0.0.1');
server.on('listening', async () => {
  const base = 'http://127.0.0.1:' + server.address().port;
  let ok = true;
  const check = (cond, what) => { if (!cond) { ok = false; console.error('  smoke FAIL: ' + what); } };
  try {
    const page = await fetch(base + '/');
    check(page.status === 200 && (await page.text()).includes('id="root"'), 'GET / serves the page');
    const js = await fetch(base + '/app.js');
    check(js.status === 200 && (js.headers.get('content-type') || '').includes('javascript'), 'GET /app.js is javascript');
    const css = await fetch(base + '/index.css');
    check(css.status === 200, 'GET /index.css');
    const missing = await fetch(base + '/api/file?path=' + encodeURIComponent(scratch));
    check(missing.status === 404, 'GET of a new file is 404');
    const put = await fetch(base + '/api/file?path=' + encodeURIComponent(scratch), { method: 'PUT', body: '{"type":"excalidraw","version":2,"elements":[]}' });
    check(put.status === 204, 'PUT writes the file');
    const back = await fetch(base + '/api/file?path=' + encodeURIComponent(scratch));
    check(back.status === 200 && (await back.json()).type === 'excalidraw', 'GET reads it back');
    const bad = await fetch(base + '/api/file?path=' + encodeURIComponent(scratch), { method: 'PUT', body: 'not json' });
    check(bad.status === 500, 'PUT of non-JSON is refused');
    const outside = await fetch(base + '/api/file?path=' + encodeURIComponent('/etc/passwd'));
    check(outside.status === 400, 'only *.excalidraw paths are served');
  } catch (e) {
    ok = false;
    console.error('  smoke FAIL: ' + e.message);
  }
  fs.rmSync(path.dirname(scratch), { recursive: true, force: true });
  server.close(() => process.exit(ok ? 0 : 1));
});
SMOKEEOF
        warn "the server smoke test failed"
        return 1
    fi
    log "verified: page, bundle, css, and the file API round-trip"
}

# ── main ────────────────────────────────────────────────────────────────────
log "=== Excalidraw editor (@excalidraw/excalidraw ${EXCALIDRAW_VERSION}) ==="
if [ "$EXCALIDRAW_FORCE" != "1" ] && [ "$(installed_version)" = "$EXCALIDRAW_VERSION" ] && [ -s "${EXCALIDRAW_DIR}/app/app.js" ]; then
    log "already built at ${EXCALIDRAW_DIR}/app (EXCALIDRAW_FORCE=1 rebuilds)"
else
    build_app || die "the Excalidraw build failed"
fi
mkdir -p "$EXCALIDRAW_DIR"
write_server
write_launcher
verify || die "the Excalidraw install did not pass its checks"

configured=""
for u in $EXCALIDRAW_USERS; do
    setup_user "$u" && configured="${configured} ${u}"
done
[ -n "${configured// /}" ] || warn "no user got the :Excalidraw command (no Neovim config found)"

log "=== done: ${EXCALIDRAW_DIR}/app on 127.0.0.1:${EXCALIDRAW_PORT} for:${configured:- nobody} ==="
log "in nvim: :Excalidraw [file]  or  <leader>me   |  in a shell: excalidraw <file>"
