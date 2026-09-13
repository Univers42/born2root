#!/usr/bin/env hellish
# Mermaid drawn inside a markdown buffer: 52-b2b-mermaid.lua, lifted out of
# setup/install/nvim/install_nvim_extras.sh and run in a real headless Neovim
# against a stand-in mermaid-ascii. No VM, no network.
#
# Asked for on 2026-09-13: "I want to see the mermaid inside nvim", not only in
# the browser preview. These pin what makes that trustworthy:
#   - a closed ```mermaid block gets the renderer's output on virtual lines
#     under its closing fence, and the file's text is untouched;
#   - a diagram type the renderer refuses becomes ONE short note, not an error;
#   - fences are matched CommonMark's way, so a ```mermaid quoted inside a
#     longer fence, or a block still being typed, is not drawn;
#   - editing the block redraws it; the toggle removes and restores drawings;
#   - a missing binary says so under the block.
#
# Needs nvim 0.10+ (vim.system). Skipped, not failed, where there is none.
set -e

cd "$(dirname "$0")/.."

if ! command -v nvim >/dev/null 2>&1 ||
    ! nvim --clean --headless -c 'lua if vim.system == nil then vim.cmd "cquit 1" end' -c qa >/dev/null 2>&1; then
    echo "skip test_mermaid_render.sh: nvim 0.10+ is not installed"
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The stand-in: boxes each source line, refuses `pie`, records its arguments.
cat >"$TMP/mermaid-ascii" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$TMP/args"
src=\$(cat)
case "\$src" in
*pie*)
    echo 'time="x" level=fatal msg="failed to parse graph diagram: unsupported graph type '"'"'pie title Pets'"'"'. Supported types: graph"' >&2
    exit 1
    ;;
esac
printf '%s\n' "\$src" | sed 's/^ */[box] /'
EOF
chmod +x "$TMP/mermaid-ascii"

# The drop-in, as the installer writes it, pointed at the stand-in.
{
    printf "local MERMAID_BIN = '%s'\n" "$TMP/mermaid-ascii"
    awk '/^    cat >>"\$\{cfg\}\/plugin\/52-b2b-mermaid.lua" <<.LUAEOF.$/ { on = 1; next } on && /^LUAEOF$/ { exit } on { print }' \
        setup/install/nvim/install_nvim_extras.sh
} >"$TMP/52-b2b-mermaid.lua"
if [ "$(wc -l <"$TMP/52-b2b-mermaid.lua")" -lt 20 ]; then
    echo "FAIL 52-b2b-mermaid.lua could not be extracted from install_nvim_extras.sh"
    exit 1
fi

cat >"$TMP/doc.md" <<'EOF'
# Notes

```mermaid
graph TD
  A --> B
```

````markdown
```mermaid
graph LR
  Quoted --> NotDrawn
```
````

```mermaid
pie title Pets
  "Dogs" : 3
```

```mermaid
graph LR
  Open --> NeverClosed
EOF

cat >"$TMP/driver.lua" <<'EOF'
local out = {}
local function say(k, v) out[#out + 1] = k .. '=' .. tostring(v) end
local ns = vim.api.nvim_create_namespace 'b2b-mermaid'
local function marks()
  local r = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })) do
    local text = {}
    for _, vl in ipairs(m[4].virt_lines or {}) do text[#text + 1] = vl[1][1] end
    r[#r + 1] = { row = m[2] + 1, text = table.concat(text, '|') }
  end
  table.sort(r, function(a, b) return a.row < b.row end)
  return r
end
local function settle(n) vim.wait(3000, function() return #marks() == n end, 20) vim.wait(100) end

vim.cmd('edit ' .. vim.g.doc)
local lines_before = vim.api.nvim_buf_line_count(0)
settle(2)
local m = marks()
say('count', #m)
say('first_row', m[1] and m[1].row)
say('first_text', m[1] and m[1].text)
say('second_row', m[2] and m[2].row)
say('second_text', m[2] and m[2].text)
say('buffer_lines_unchanged', vim.api.nvim_buf_line_count(0) == lines_before)
say('not_modified', not vim.bo.modified)

-- edit the first diagram: rename B to C
vim.api.nvim_buf_set_lines(0, 4, 5, false, { '  A --> C' })
vim.api.nvim_exec_autocmds('TextChanged', { buffer = 0 })
vim.wait(3000, function() local x = marks() return x[1] and x[1].text:find('C', 1, true) ~= nil end, 20)
say('after_edit', marks()[1] and marks()[1].text)

vim.cmd 'B2BMermaid off'
say('off_count', #marks())
vim.cmd 'B2BMermaid on'
settle(2)
say('on_count', #marks())

vim.fn.writefile(out, vim.g.out)
vim.cmd 'qa!'
EOF

check() {
    if [ "$2" = "$3" ]; then
        printf 'ok   %-46s = %s\n' "$1" "$3"
    else
        printf 'FAIL %-46s = %s (expected %s)\n' "$1" "$2" "$3"
        fail=1
    fi
}
fail=0
get() { sed -n "s/^$1=//p" "$TMP/out"; }

nvim --clean --headless --cmd "let g:doc='$TMP/doc.md' | let g:out='$TMP/out'" \
    -c "luafile $TMP/52-b2b-mermaid.lua" -c "luafile $TMP/driver.lua" >/dev/null 2>&1 || true
if [ ! -s "$TMP/out" ]; then
    echo "FAIL the headless Neovim run produced no results"
    exit 1
fi
check "two blocks drawn (quoted and unclosed skipped)" "$(get count)" "2"
check "flowchart drawn under its closing fence" "$(get first_row)" "6"
check "...with the renderer's output" "$(get first_text)" "[box] graph TD|[box] A --> B"
check "pie becomes one note under its fence" "$(get second_row)" "18"
check "...naming the refusal and the way out" "$(get second_text)" \
    "mermaid: unsupported graph type 'pie title Pets' -- <leader>mp shows it in the browser"
check "no text is added to the buffer" "$(get buffer_lines_unchanged)" "true"
check "the buffer is not marked modified" "$(get not_modified)" "true"
check "editing the block redraws it" "$(get after_edit)" "[box] graph TD|[box] A --> C"
check ":B2BMermaid off removes the drawings" "$(get off_count)" "0"
check ":B2BMermaid on brings them back" "$(get on_count)" "2"
check "compact boxes and a width limit are asked for" \
    "$(head -n1 "$TMP/args" | grep -c -- '-f - -p 0 --max-width')" "1"

# The binary missing: a note, not an error.
sed -i "1s|.*|local MERMAID_BIN = '$TMP/does-not-exist'|" "$TMP/52-b2b-mermaid.lua"
cat >"$TMP/driver2.lua" <<'EOF'
local ns = vim.api.nvim_create_namespace 'b2b-mermaid'
vim.cmd('edit ' .. vim.g.doc)
vim.wait(3000, function() return #vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, {}) > 0 end, 20)
local m = vim.api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })[1]
vim.fn.writefile({ m and m[4].virt_lines[1][1][1] or 'none' }, vim.g.out)
vim.cmd 'qa!'
EOF
rm -f "$TMP/out"
nvim --clean --headless --cmd "let g:doc='$TMP/doc.md' | let g:out='$TMP/out'" \
    -c "luafile $TMP/52-b2b-mermaid.lua" -c "luafile $TMP/driver2.lua" >/dev/null 2>&1 || true
check "a missing binary is named under the block" \
    "$(grep -c 'does-not-exist is not installed' "$TMP/out" 2>/dev/null || echo 0)" "1"

exit "$fail"
