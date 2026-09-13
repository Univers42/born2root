#!/usr/bin/env hellish
# The Excalidraw server, lifted out of setup/install/nvim/install_excalidraw.sh
# and run on the host with node. No VM, no browser.
#
# The bug this pins: http://localhost:8421/ -- the URL a person types -- served
# a scratch pad that saved nothing ("nothing is saved without ?file=" in its
# status line). Reported 2026-09-13: a drawing made there was gone on refresh,
# and the .excalidraw it was meant for still held the 125-byte empty scene.
# Now a bare / redirects to the drawing opened last, or to a scratch file that
# is actually saved, and every load or save through the API moves "last".
#
# Needs node 18+ (fetch). Skipped, not failed, where there is none.
set -e

cd "$(dirname "$0")/.."

if ! command -v node >/dev/null 2>&1 ||
    [ "$(node -e 'process.stdout.write(String(+process.versions.node.split(".")[0] >= 18))')" != "true" ]; then
    echo "skip test_excalidraw_server.sh: node 18+ is not installed"
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/app"
printf '<!doctype html><div id="root"></div>\n' >"$TMP/app/index.html"

# The heredoc body, byte for byte what the installer writes to server.js.
awk '/^    cat >"\$\{EXCALIDRAW_DIR\}\/server.js" <<.JSEOF.$/ { on = 1; next } on && /^JSEOF$/ { exit } on { print }' \
    setup/install/nvim/install_excalidraw.sh >"$TMP/server.js"
if ! [ -s "$TMP/server.js" ] || ! node --check "$TMP/server.js"; then
    echo "FAIL server.js could not be extracted from install_excalidraw.sh, or does not parse"
    exit 1
fi

node - "$TMP" <<'NODEEOF'
const fs = require('fs');
const path = require('path');
const dir = process.argv[2];
const { start, EMPTY_SCENE } = require(path.join(dir, 'server.js'));
const opts = { state: path.join(dir, 'state', 'excalidraw', 'last'), scratch: path.join(dir, 'data', 'scratch.excalidraw') };
const drawing = path.join(dir, 'notes', 'arch.excalidraw');
fs.mkdirSync(path.dirname(drawing), { recursive: true });

let fail = 0;
const check = (what, got, want) => {
  const ok = got === want;
  if (!ok) fail = 1;
  console.log((ok ? 'ok   ' : 'FAIL ') + what.padEnd(52) + ' = ' + got + (ok ? '' : ' (expected ' + want + ')'));
};
const target = (res) => decodeURIComponent((res.headers.get('location') || '').replace(/^\/\?file=/, ''));

const server = start(0, '127.0.0.1', opts);
server.on('listening', async () => {
  const base = 'http://127.0.0.1:' + server.address().port;
  const file = (p) => base + '/api/file?path=' + encodeURIComponent(p);
  try {
    let r = await fetch(base + '/', { redirect: 'manual' });
    check('bare / with no history redirects', r.status, 302);
    check('...to the scratch file', target(r), opts.scratch);
    check('the scratch file was created as a scene', JSON.parse(fs.readFileSync(opts.scratch, 'utf8')).type, 'excalidraw');
    r = await fetch(base + '/index.html', { redirect: 'manual' });
    check('/index.html without ?file= redirects too', r.status, 302);

    r = await fetch(base + '/?file=' + encodeURIComponent(drawing));
    check('/?file= serves the page itself', r.status, 200);

    // What :Excalidraw and the launcher do before printing a URL.
    fs.mkdirSync(path.dirname(opts.state), { recursive: true });
    fs.writeFileSync(opts.state, drawing + '\n');
    fs.writeFileSync(drawing, EMPTY_SCENE);
    r = await fetch(base + '/', { redirect: 'manual' });
    check('bare / opens the drawing :Excalidraw recorded', target(r), drawing);

    // A recorded file that has since been deleted falls back to scratch.
    fs.unlinkSync(drawing);
    r = await fetch(base + '/', { redirect: 'manual' });
    check('a recorded file that is gone falls back', target(r), opts.scratch);

    const scene = '{"type":"excalidraw","version":2,"elements":[{"id":"a","type":"rectangle"}],"appState":{},"files":{}}';
    r = await fetch(file(drawing), { method: 'PUT', body: scene });
    check('PUT writes the drawing', r.status, 204);
    check('...byte for byte', fs.readFileSync(drawing, 'utf8'), scene);
    check('...with no temp file left behind', fs.readdirSync(path.dirname(drawing)).filter((n) => n.includes('.tmp-')).length, 0);
    r = await fetch(base + '/', { redirect: 'manual' });
    check('a save makes it the drawing / opens', target(r), drawing);

    r = await fetch(file(drawing), { method: 'PUT', body: 'not json' });
    check('non-JSON for a .excalidraw is refused', r.status, 500);
    check('...and the file keeps its content', fs.readFileSync(drawing, 'utf8'), scene);
    r = await fetch(file('/etc/passwd'));
    check('only *.excalidraw paths are served', r.status, 400);
    r = await fetch(file(drawing + '.svg'), { method: 'PUT', body: '<svg/>' });
    check('the .svg beside it is written', r.status, 204);
    check('...and does not become the drawing / opens', fs.readFileSync(opts.state, 'utf8').trim(), drawing);
  } catch (e) {
    fail = 1;
    console.log('FAIL ' + e.message);
  }
  server.close(() => process.exit(fail));
});
NODEEOF
