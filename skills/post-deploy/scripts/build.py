#!/usr/bin/env python3
"""Build the post-deploy checklist data from the PRs' "Deploy steps" and "After deploy" sections.

    build.py [--quiet] [--since YYYY-MM-DD]

Repos: every manager registry (~/.claude/task-briefs*/tick.env) with REPOS and DEPLOY_LIST not off.
PRs:   merged since max(SINCE, today-2d), every older PR that still has unchecked steps, and open
       non-draft PRs whose title or branch names a ticket registered in that folder (ready to merge).
Writes ~/.claude/post-deploy/data.json only when something changed. No Claude, no tokens.
"""
import datetime as dt, glob, hashlib, html, json, os, re, subprocess, sys

HOME = os.path.expanduser('~')
DIR = os.environ.get('POST_DEPLOY_DIR', f'{HOME}/.claude/post-deploy')
DATA, CHECKS, CONF = f'{DIR}/data.json', f'{DIR}/checks.json', f'{DIR}/config.env'
DEPLOY_LOG = f'{HOME}/.claude/manager-deploys.log'
QUIET = '--quiet' in sys.argv
SECTIONS = ('Deploy steps', 'After deploy')


def sh(cmd, cwd=None, timeout=60):
    try:
        r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout
    except Exception as e:  # noqa: BLE001
        return 1, str(e)


def read_env(path):
    out = {}
    if os.path.exists(path):
        for l in open(path):
            m = re.match(r'\s*([A-Z_]+)=(.*)', l)
            if m:
                out[m.group(1)] = m.group(2).strip().strip('"')
    return out


def main_checkout(repo):
    rc, out = sh(['git', '-C', repo, 'rev-parse', '--path-format=absolute', '--git-common-dir'])
    return os.path.dirname(out.strip()) if rc == 0 and out.strip() else repo


def slug_of(top):
    rc, out = sh(['git', '-C', top, 'remote', 'get-url', 'origin'])
    m = re.search(r'github\.com[:/]([^/]+/[^/.\s]+?)(?:\.git)?\s*$', out)
    return m.group(1) if m else None


def latest_deploys(tops):
    """{main checkout: (sha, when)} from deployed.sh lines and <repo>/log/capistrano.log."""
    ev = []
    if os.path.exists(DEPLOY_LOG):
        for l in open(DEPLOY_LOG):
            f = [x.strip() for x in l.split('|')]
            if len(f) >= 3:
                ev.append((re.sub(r'\D', '', f[0])[:14], f[1], f[2]))
    for top in tops:  # the repo's own log and one level down (e.g. web/log)
        for c in glob.glob(f'{top}/log/capistrano.log') + glob.glob(f'{top}/*/log/capistrano.log'):
            for m in re.finditer(r'Branch \S+ \(at ([0-9a-f]{40})\) deployed as release (\d{14})',
                                 open(c, errors='replace').read()):
                ev.append((m.group(2), top, m.group(1)))
    out = {}
    for when, top, sha in sorted(ev):
        if top in tops:
            out[top] = (sha, when)
    return out


# ---------- markdown, just enough for PR bodies ----------
def inline(t):
    t = html.escape(t, quote=False)
    parts = re.split(r'(`[^`]+`)', t)
    out = []
    for p in parts:
        if len(p) > 1 and p.startswith('`') and p.endswith('`'):
            out.append(f'<code>{p[1:-1]}</code>')
            continue
        p = re.sub(r'\*\*(.+?)\*\*', r'<b>\1</b>', p)
        p = re.sub(r'\[([^\]]+)\]\((https?://[^)\s]+)\)', r'<a href="\2" target="_blank">\1</a>', p)
        p = re.sub(r'(?<![">])(https?://[^\s<)]+)', r'<a href="\1" target="_blank">\1</a>', p)
        out.append(p)
    return ''.join(out)


LI = re.compile(r'^(\s*)(?:[-*+]|\d+[.)])\s+(.*)$')


def section(body, name):
    m = re.search(rf'^##\s+{re.escape(name)}\s*$(.*?)(?=^##\s|\Z)', body or '', re.M | re.S)
    return m.group(1) if m else None


def parse(text):
    """Blocks: {kind: task|head|note|ref|none, depth, text, code: [..]}."""
    blocks, cur, fence = [], None, None
    for line in text.splitlines():
        if fence is not None:
            if line.strip().startswith('```'):
                (cur if cur else blocks[-1])['code'].append('\n'.join(fence))
                fence = None
            else:
                fence.append(line)
            continue
        if line.strip().startswith('```'):
            fence = []
            if not blocks:
                blocks.append({'kind': 'note', 'depth': 0, 'text': '', 'code': []})
            continue
        if not line.strip():
            cur = None if cur and cur['kind'] == 'note' else cur
            continue
        m = LI.match(line)
        if m:
            depth = 1 if len(m.group(1).replace('\t', '    ')) >= 2 else 0
            cur = {'kind': 'task', 'depth': depth, 'text': m.group(2).strip(), 'code': []}
            blocks.append(cur)
        elif cur and line.startswith((' ', '\t')):
            cur['text'] += ' ' + line.strip()
        else:
            cur = {'kind': 'note', 'depth': 0, 'text': line.strip(), 'code': []}
            blocks.append(cur)
    if fence and blocks:
        blocks[-1]['code'].append('\n'.join(fence))
    for i, b in enumerate(blocks):
        if b['kind'] != 'task':
            continue
        low = b['text'].lower()
        rest = re.sub(r'^[\w ]{1,24}:\s*', '', low)  # "Check: nothing", "Left for you: nothing"
        nxt = blocks[i + 1] if i + 1 < len(blocks) else None
        if re.match(r'(rollback|too noisy|if )', low):
            b['kind'] = 'ref'
        elif re.match(r'left for [\w ]+:\s*(the )?(deploy )?steps? [\d–\-, and]+\.?$', low):
            b['kind'] = 'none'  # only points back at the steps above
        elif re.match(r'(nothing|none\b|no )', low) or re.match(r'(nothing|none\b)', rest) or 'nothing to check' in low:
            b['kind'] = 'none'
        elif nxt and nxt['depth'] > b['depth'] and nxt['kind'] == 'task' and b['text'].rstrip().endswith(':'):
            b['kind'] = 'head'
    return blocks


def pr_entry(repo_name, pr, state, deploy):
    key = f'{repo_name}#{pr["number"]}'
    secs, seen = [], {}
    for name in SECTIONS:
        raw = section(pr.get('body'), name)
        blocks = parse(raw) if raw is not None else []
        out = []
        for b in blocks:
            base = f'{key}|{name}|{b["text"]}'
            seen[base] = seen.get(base, 0) + 1
            iid = hashlib.sha1(f'{base}|{seen[base]}'.encode()).hexdigest()[:12]
            auto = bool(b['kind'] == 'task' and (
                (deploy.get('status') == 'deployed' and re.search(r'\bcap\b[^`]*\bdeploy\b(?!:rollback)', b['text']))
                or (state == 'merged' and re.match(r'(squash-)?merge (this|the) pr\b', b['text'].lower()))))
            out.append({'id': iid, 'kind': b['kind'], 'depth': b['depth'], 'html': inline(b['text']),
                        'code': b['code'], 'auto': auto})
        secs.append({'name': name, 'missing': raw is None, 'blocks': out})
    return {'key': key, 'repo': repo_name, 'number': pr['number'], 'title': pr['title'], 'url': pr['url'],
            'state': state, 'mergedAt': pr.get('mergedAt'), 'deploy': deploy, 'sections': secs,
            'tasks': sum(1 for s in secs for b in s['blocks'] if b['kind'] == 'task')}


def main():
    os.makedirs(DIR, exist_ok=True)
    conf = read_env(CONF)
    since = conf.get('SINCE', '2000-01-01')
    if '--since' in sys.argv:
        since = sys.argv[sys.argv.index('--since') + 1]
    floor = (dt.date.today() - dt.timedelta(days=int(conf.get('KEEP_DAYS', '2')))).isoformat()
    since = max(since, floor)
    checks = json.load(open(CHECKS)) if os.path.exists(CHECKS) else {}
    old = json.load(open(DATA)) if os.path.exists(DATA) else {'prs': []}

    repos, keys = [], set()
    for te in sorted(glob.glob(f'{HOME}/.claude/task-briefs*/tick.env')):
        env = read_env(te)
        if env.get('DEPLOY_LIST', 'on') == 'off' or not env.get('REPOS'):
            continue
        repos += env['REPOS'].split()
        for f in glob.glob(os.path.join(os.path.dirname(te), '*.env')):
            e = read_env(f)
            for k in (e.get('JIRA_KEY'), e.get('KEY')):
                if k and re.match(r'^[A-Z]+-\d+$', k):
                    keys.add(k)

    tops = {}
    for r in dict.fromkeys(repos):
        top = main_checkout(r)
        if os.path.isdir(top):
            tops[top] = slug_of(top)
    deployed = latest_deploys(set(tops))

    prs, errors = [], []
    for top, slug in tops.items():
        if not slug:
            continue
        name = slug.split('/')[1]
        fields = 'number,title,url,body,mergedAt,mergeCommit,headRefName,isDraft'
        rc, out = sh(['gh', 'pr', 'list', '-R', slug, '--state', 'merged', '--search', f'merged:>={since}',
                      '--limit', '100', '--json', fields])
        merged = json.loads(out) if rc == 0 else []
        if rc != 0:
            errors.append(f'{slug}: gh pr list merged failed')
        have = {p['number'] for p in merged}
        for o in old.get('prs', []):  # carry older PRs that still have unchecked steps
            if o['repo'] == name and o['state'] == 'merged' and o['number'] not in have:
                undone = any(b['kind'] == 'task' and not b['auto'] and b['id'] not in checks
                             for s in o['sections'] for b in s['blocks'])
                if undone:
                    rc2, out2 = sh(['gh', 'pr', 'view', str(o['number']), '-R', slug, '--json', fields])
                    if rc2 == 0:
                        merged.append(json.loads(out2))
        dep = deployed.get(top)
        fetched = False
        for p in merged:
            oid = (p.get('mergeCommit') or {}).get('oid')
            if not dep:
                d = {'status': 'unknown'}
            else:
                if oid and sh(['git', '-C', top, 'cat-file', '-e', f'{oid}^{{commit}}'])[0] != 0 and not fetched:
                    sh(['git', '-C', top, 'fetch', '-q', 'origin'], timeout=90)
                    fetched = True
                inside = oid and sh(['git', '-C', top, 'merge-base', '--is-ancestor', oid, dep[0]])[0] == 0
                when = dt.datetime.strptime(dep[1], '%Y%m%d%H%M%S').strftime('%Y-%m-%d %H:%M') if len(dep[1]) == 14 else dep[1]
                d = {'status': 'deployed', 'when': when, 'sha': dep[0][:8]} if inside else \
                    {'status': 'waiting', 'last': when, 'sha': dep[0][:8]}
            prs.append(pr_entry(name, p, 'merged', d))
        rc, out = sh(['gh', 'pr', 'list', '-R', slug, '--state', 'open', '--limit', '60', '--json', fields])
        if rc != 0:
            errors.append(f'{slug}: gh pr list open failed')
        for p in (json.loads(out) if rc == 0 else []):
            ks = set(re.findall(r'[A-Z]+-\d+', f'{p["title"]} {p["headRefName"]}'))
            if not p['isDraft'] and ks & keys:
                prs.append(pr_entry(name, p, 'open', {'status': 'not merged'}))

    prs.sort(key=lambda p: p.get('mergedAt') or '9999', reverse=True)
    body = {'prs': prs, 'errors': errors, 'since': since}
    version = hashlib.sha1(json.dumps(body, sort_keys=True).encode()).hexdigest()[:12]
    if version == old.get('version'):
        QUIET or print(f'post-deploy: no change ({len(prs)} PRs)')
        return
    body.update(version=version, built=dt.datetime.now().strftime('%Y-%m-%d %H:%M'))
    tmp = DATA + '.tmp'
    json.dump(body, open(tmp, 'w'), indent=1)
    os.replace(tmp, DATA)
    print(f'post-deploy: updated ({len(prs)} PRs, {sum(p["tasks"] for p in prs)} steps)')


if __name__ == '__main__':
    main()
