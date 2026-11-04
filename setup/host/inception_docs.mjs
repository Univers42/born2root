// setup/host/inception_docs.mjs: publish Inception's USER_DOC.md and DEV_DOC.md
// into the osionos workspace as native pages, one per guide and one per "## "
// section, read straight from the VM (ssh b2b). Page ids derive from titles, so a
// rerun updates the same pages instead of adding copies.
//
//   make inception_docs        (OSIONOS_EMAIL / OSIONOS_PASSWORD from the secrets file)
//
// Caveat: inline Markdown (**bold**, `code`) is passed through as text and relies
// on osionos's renderer; nested lists flatten to one level, and a renamed section
// becomes a new page while the old one stays until removed by hand.
import fs from 'fs';
import crypto from 'crypto';
import { execFileSync } from 'child_process';

const API = process.env.OSIONOS_API || 'https://baas-beta.tail10f2ea.ts.net:10000';
const ORIGIN = process.env.OSIONOS_ORIGIN || 'https://baas-beta.tail10f2ea.ts.net';
const I = process.env.OSIONOS_WORKSPACE || 'dad07d44-c78d-4660-8738-81476982ab38';
const SSH = process.env.SSH_ALIAS || 'b2b';
const GUEST_DIR = process.env.INCEPTION_DIR || 'Documents/inception';
let TOKEN = '';
async function api(m, p, b) {
    const r = await fetch(API + p, { method: m, headers: { authorization: 'Bearer ' + TOKEN, origin: ORIGIN, 'content-type': 'application/json' }, body: b ? JSON.stringify(b) : undefined });
    const t = await r.text();
    let j;
    try { j = JSON.parse(t); } catch { j = t.slice(0, 400); }
    return { s: r.status, j };
}
async function login() {
    const email = process.env.OSIONOS_EMAIL, password = process.env.OSIONOS_PASSWORD;
    if (!email || !password) throw new Error('OSIONOS_EMAIL and OSIONOS_PASSWORD are not set (secrets file)');
    const r = await api('POST', '/api/auth/login', { email, password });
    if (r.s !== 200 || !r.j.accessToken) throw new Error('osionos refused the login: ' + r.s);
    TOKEN = r.j.accessToken;
}
const readGuest = (f) => execFileSync('ssh', ['-T', '-o', 'BatchMode=yes', '-o', 'ClearAllForwardings=yes', SSH, `cat '${GUEST_DIR}/${f}'`], { encoding: 'utf8' });
const DRY = process.argv.includes('--dry');
const uid = () => crypto.randomUUID();
const pageId = (name) => {
    const h = crypto.createHash('sha256').update('inception-docs:' + name).digest('hex');
    return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-a${h.slice(17, 20)}-${h.slice(20, 32)}`;
};
const block = (type, content = '', extra = {}) => ({ id: uid(), type, content, ...extra });

function splitRow(line) {
    const cells = [];
    let cur = '';
    let code = false;
    const s = line.trim().replace(/^\|/, '').replace(/\|$/, '');
    for (let i = 0; i < s.length; i++) {
        const c = s[i];
        if (c === '\\' && s[i + 1] === '|') { cur += '|'; i++; continue; }
        if (c === '`') code = !code;
        if (c === '|' && !code) { cells.push(cur.trim()); cur = ''; continue; }
        cur += c;
    }
    cells.push(cur.trim());
    return cells;
}

const isTableSep = (l) => /^\s*\|?\s*:?-{3,}/.test(l) && /^[\s|:-]+$/.test(l);

// Markdown lines -> osionos blocks.
function toBlocks(lines) {
    const out = [];
    let i = 0;
    const para = [];
    const flush = () => { if (para.length) { out.push(block('paragraph', para.join(' '))); para.length = 0; } };
    while (i < lines.length) {
        const raw = lines[i];
        const line = raw.trimEnd();
        const t = line.trim();
        const fence = /^```(\S*)/.exec(t);
        if (fence) {
            flush();
            const indent = raw.length - raw.trimStart().length;
            const code = [];
            i++;
            while (i < lines.length && !/^```\s*$/.test(lines[i].trim())) { code.push(lines[i].slice(indent)); i++; }
            i++;
            out.push(block('code', code.join('\n'), { language: fence[1] || 'plaintext' }));
            continue;
        }
        if (!t) { flush(); i++; continue; }
        if (/^---+$/.test(t)) { flush(); out.push(block('divider')); i++; continue; }
        const h = /^(#{3,6})\s+(.+)$/.exec(t);
        if (h) { flush(); out.push(block(h[1].length === 3 ? 'heading_2' : 'heading_3', h[2])); i++; continue; }
        if (t.startsWith('|') && i + 1 < lines.length && isTableSep(lines[i + 1])) {
            flush();
            const rows = [splitRow(t)];
            i += 2;
            while (i < lines.length && lines[i].trim().startsWith('|')) { rows.push(splitRow(lines[i])); i++; }
            out.push(block('table_block', '', { tableData: rows }));
            continue;
        }
        if (t.startsWith('>')) {
            flush();
            const q = [];
            while (i < lines.length && lines[i].trim().startsWith('>')) { q.push(lines[i].trim().replace(/^>\s?/, '')); i++; }
            const inner = toBlocks(q);
            const text = inner.filter((b) => b.type === 'paragraph').map((b) => b.content).join(' ');
            out.push(block('callout', text, { color: '💡' }));
            for (const b of inner) if (b.type !== 'paragraph') out.push(b);
            continue;
        }
        const li = /^(\s*)([-*]|\d+[.)])\s+(.+)$/.exec(line);
        if (li) {
            flush();
            const type = /\d/.test(li[2]) ? 'numbered_list' : 'bulleted_list';
            let text = li[3];
            const base = li[1].length;
            i++;
            while (i < lines.length && lines[i].trim() && !/^\s*([-*]|\d+[.)])\s+/.test(lines[i]) &&
                !/^\s*```/.test(lines[i]) && (lines[i].length - lines[i].trimStart().length) > base) {
                text += ' ' + lines[i].trim();
                i++;
            }
            // A list resumed after a code block would restart at 1 in osionos:
            // keep its own number instead.
            const num = /^(\d+)/.exec(li[2]);
            if (num && num[1] !== '1' && out.at(-1)?.type !== 'numbered_list') out.push(block('paragraph', `**${num[1]}.** ${text}`));
            else out.push(block(type, text));
            continue;
        }
        para.push(t);
        i++;
    }
    flush();
    return out;
}

function sections(md) {
    const lines = md.split('\n');
    const intro = [];
    const parts = [];
    let cur = null;
    let inCode = false;
    for (const l of lines) {
        if (/^\s*```/.test(l)) inCode = !inCode;
        if (!inCode && /^# /.test(l)) continue;
        if (!inCode && /^## /.test(l)) { cur = { title: l.replace(/^## /, '').replace(/`/g, '').trim(), lines: [] }; parts.push(cur); continue; }
        (cur ? cur.lines : intro).push(l);
    }
    for (const p of parts) while (p.lines.length && /^(---|\s*)$/.test(p.lines.at(-1))) p.lines.pop();
    while (intro.length && /^(---|\s*)$/.test(intro.at(-1))) intro.pop();
    return { intro, parts };
}

const button = (label, id, variant = 'secondary') =>
    block('button', label, { buttonHref: 'page://' + id, buttonLabel: label, buttonVariant: variant });

async function upsert(id, title, icon, parentPageId, content) {
    const body = { id, workspaceId: I, title, icon, parentPageId, content };
    const size = Buffer.byteLength(JSON.stringify(body));
    if (size > 120000) throw new Error(`${title}: ${size} bytes, over the edge limit`);
    if (DRY) return `dry ${size}B`;
    const got = await api('GET', '/api/pages/' + id);
    if (got.s === 200 && got.j && !got.j.archivedAt) {
        const r = await api('PATCH', '/api/pages/' + id, { title, icon, content });
        if (r.s !== 200) throw new Error(`${title}: PATCH ${r.s} ${JSON.stringify(r.j).slice(0, 160)}`);
        return `updated ${size}B`;
    }
    const r = await api('POST', '/api/pages', body);
    if (r.s !== 201 && r.s !== 200) throw new Error(`${title}: POST ${r.s} ${JSON.stringify(r.j).slice(0, 160)}`);
    return `created ${size}B`;
}

const ROOT = pageId('root');
const GUIDES = [
    { key: 'user', file: 'USER_DOC.md', title: 'User guide', icon: '👤' },
    { key: 'dev', file: 'DEV_DOC.md', title: 'Developer guide', icon: '🛠️' },
];

await login();
const report = [];
const rootContent = [
    block('callout', '**Inception, documented.** The two guides of the project, as pages: the same text as `USER_DOC.md` and `DEV_DOC.md` in the repository, one page per section.', { color: '📘' }),
    block('paragraph', 'Start with the user guide to run the project. Open the developer guide for how it works, where the data lives, how to reproduce everything, and why it builds fast.'),
    ...GUIDES.map((g) => button(`${g.icon} ${g.title}`, pageId(g.key), g.key === 'user' ? 'primary' : 'secondary')),
];
report.push(['Inception documentation', await upsert(ROOT, 'Inception documentation', '📘', undefined, rootContent)]);

for (const g of GUIDES) {
    const { intro, parts } = sections(readGuest(g.file));
    const gid = pageId(g.key);
    const content = [
        button('← 📘 Inception documentation', ROOT),
        ...toBlocks(intro),
        block('heading_2', 'Sections'),
        ...parts.map((p) => button(p.title, pageId(`${g.key}:${p.title}`))),
    ];
    report.push([g.title, await upsert(gid, g.title, g.icon, ROOT, content)]);
    for (const [n, p] of parts.entries()) {
        const blocks = toBlocks(p.lines);
        const nav = [button(`← ${g.icon} ${g.title}`, gid)];
        if (parts[n + 1]) nav.push(button(`Next: ${parts[n + 1].title} →`, pageId(`${g.key}:${parts[n + 1].title}`)));
        const pc = [nav[0], ...blocks, block('divider'), ...nav];
        const types = blocks.reduce((a, b) => (a[b.type] = (a[b.type] || 0) + 1, a), {});
        report.push([`  ${p.title}`, await upsert(pageId(`${g.key}:${p.title}`), p.title, g.icon, gid, pc), JSON.stringify(types)]);
    }
}
for (const r of report) console.log(r.join('  '));
console.log('root page', ROOT);
