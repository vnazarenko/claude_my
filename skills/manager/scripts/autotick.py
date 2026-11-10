#!/usr/bin/env python3
"""One cheap manager tick: no Claude call unless a question really needs one.

Run by the manager session on every cron fire. It prints a few short lines; the manager reads
them. Steps:
  1. For every watched session (registry + long-lived), read the screen. A WORKING session or a
     screen that did not change since the last tick is skipped (no model call).
  2. Events from GitHub, no model: a ticket's PR became CONFLICTING, or got MERGED -> a fixed
     message to the session (say.sh).
  3. A changed, idle screen goes to Jev (typesafe.ai, ~900 tokens, ~$0.00004): is a question
     waiting, does it touch production / money / what customers see / a server that is down,
     is the work finished? User-only -> a needs line. No question and finished -> nothing.
  4. Whatever is left is printed as `ASK <KEY> <file>`: the manager (Claude) reads only that file
     and decides, with rules.md.

Output lines:  `sent KEY: ...`  `needs KEY: ...`  `ASK KEY <file>`  `skip: ...`  `IDLE: ...`
Exit: 0 = done, nothing for Claude; 10 = ASK lines printed; 3 = agterm not answering; 4 = busy.

Why: token audit 2026-11-06 - a fresh agent per tick cost 150k-310k weighted tokens, ~390 ticks a
week took ~10% of the weekly limit, and almost every tick found "no change".
"""
import hashlib, json, os, re, shutil, subprocess, sys, time
from datetime import datetime

HOME = os.path.expanduser('~')
BRIEFS = os.environ.get('MANAGER_BRIEFS', f'{HOME}/.claude/task-briefs')
SCRIPTS = f'{HOME}/.claude/skills/manager/scripts'
STATE = f'{BRIEFS}/.auto-state.json'
# Per-manager project settings (<briefs>/tick.env): CLAUDE_CONFIG_DIR, CLAUDE_CWD, PROJECT_DIR,
# MERGE_FOLLOWUP (task-cleanup | post-merge-watch), DEPLOY_LIST (on | off).
# REPOS: every repo of the project (space separated), searched for open PRs before a cleanup.
TE = {}
LOCK = f'{BRIEFS}/.manager-tick.lock'
ASKDIR = f'{BRIEFS}/.ask'
KEYFILE = f'{HOME}/.config/typesafe/.env'
IDLE_STOP = int(os.environ.get('IDLE_STOP', '2'))
NOW = datetime.now().strftime('%Y-%m-%d %H:%M')
# Homebrew bash: lib-screens.sh is slow to a hang under macOS /bin/bash 3.2 (${t//[[:space:]]/} on 90k).
BASH = shutil.which('bash') or '/bin/bash'
DRY = '--dry' in sys.argv
RESTATE_NOW = '--restate' in sys.argv  # with --retint: also ask waiting sessions to restate open questions
RETINT = '--retint' in sys.argv or RESTATE_NOW  # recolour every idle session once (Jev only, no Claude)
RUN_ASKS = '--run-asks' in sys.argv  # launchd mode: handle ASK items with a small claude -p each  # classify and print, send nothing, write nothing


def sh(cmd, inp=None, timeout=30):
    try:
        r = subprocess.run(cmd, input=inp, capture_output=True, text=True, timeout=timeout,
                           shell=isinstance(cmd, str), executable=BASH if isinstance(cmd, str) else None,
                           stdin=subprocess.DEVNULL if inp is None else None)
        return r.returncode, r.stdout
    except subprocess.TimeoutExpired:
        return 124, ''


def lib(fn, *args):
    q = ' '.join("'" + a.replace("'", "'\\''") + "'" for a in args)
    return sh(f'briefs="{BRIEFS}"; . "{SCRIPTS}/lib-screens.sh"; {fn} {q}', timeout=60)[1]


def log(key, text):
    if DRY:
        return
    with open(f'{BRIEFS}/manager-log.md', 'a') as f:
        f.write(f'{NOW} | {key} | {text}\n')


def say(key, sid, text):
    if DRY:
        return 'dry'
    rc, out = sh([BASH, f'{SCRIPTS}/say.sh', sid, text], timeout=60)
    return {0: 'sent', 2: 'skipped (user is in the session)', 3: 'agterm not answering'}.get(rc, f'error {rc}')


def envfile(path):
    d = {}
    for l in open(path):
        if '=' in l and not l.startswith('#'):
            k, v = l.rstrip('\n').split('=', 1)
            d[k] = v.strip().strip('"')
    return d


# ---------- Jev ----------
N = lambda t: {"type": "noul", "instructions": t}
JEV_Q = {
    "asks": N("Does the agent's LAST message end with a question or a choice menu that waits for an answer before it can go on?"),
    "prod": N("Is the pending question about production: deploying, a production server or host, running something on prod, or reading or changing production data?"),
    "money": N("Would answering yes spend money (paid proxies, paid services, buying something)?"),
    "visible": N("Is the pending question a product decision about what customers or API users will see or get (chart content, notes, texts, prices, status codes, what is shown or dropped)?"),
    "down": N("Is the agent blocked because a server or machine is down or unreachable and someone must fix it?"),
    "post": N("Is the pending question whether to post, send, publish or push something where other people will see it (a Jira or GitHub comment, a PR review, a Slack message, a git push)?"),
    "design": N("Does the agent show a design, mockup or page and wait for someone to approve or choose it?"),
    "clear": N("Does the agent's last message list each open question for the owner with the problem in plain words and at least two concrete options to choose from (or one clear yes/no action)?"),
    "mergedwait": N("Is the agent's work merged, so it only waits for a deploy, a check after the deploy, or the cleanup, with no open pull request and no other work left?"),
    "done": N("Has the agent finished its work and printed a final summary, so it only waits for the owner now?"),
    # session colours (user rule 2026-11-09): green = can close, red = problem, yellow = testing / watching
    "closable": N("Does the agent say its work is fully complete and the session can be closed, with nothing left to do or decide?"),
    "problem": N("Is the agent stuck on an error or problem: failing tests or CI, a crash, a broken deploy, an alert, or a blocker it cannot fix itself?"),
    "testing": N("Is the agent testing a change before release (staging, e2e, CI run, manual checks) or watching production after a merge or deploy?"),
    "postwatch": N("Is the agent watching production after a merge or deploy (checkpoints like +15m, +1h, +3h, +6h, health, error or perf checks after release)?"),
    "pmwskill": N("Does the screen show the post-merge-watch skill is in use (/post-merge-watch, Skill(post-merge-watch), watch.py or a post-merge-watch checkpoint report)?"),
}


def has_need(key):
    p = f'{BRIEFS}/manager-needs.md'
    return os.path.exists(p) and any(l.startswith(key + ' |') for l in open(p).read().splitlines())


def all_merged(st):
    """At least one PR of the ticket merged, none open (from the stored PR states)."""
    v = [x for k, x in st.get('prs', {}).items() if not k.startswith('merged_at')]
    return any(x.startswith('MERGED') for x in v) and not any(x.startswith('OPEN') for x in v)


# Session colour: Jev picks it (user rule 2026-11-10). One question per colour, on the last 6000
# characters of the screen; the most likely answer wins, if it is at least 0.5. "wait" = no colour.
COLOUR_Q = {
    'green': N("Is this task's code already merged (or deployed), so the session only waits for a deploy, a check after the deploy, the cleanup, or to be closed?"),
    'yellow': N("Is the change not merged yet, and tests, checks or a review are running or queued for it (full suite, e2e, CI, code review), so the session goes on by itself?"),
    'red': N("Is the agent stuck on a failure it cannot fix by itself (failing tests or CI, a crash, a broken deploy, a blocker)?"),
    'clear': N("Is the change not merged yet, and the agent waits for the owner's decision or answer before it can go on?"),
}


def colour_of(screen):
    a = jev(screen, COLOUR_Q, 6000)
    if not a:
        return None
    c = max(a, key=a.get)
    return c if a[c] >= 0.5 else 'clear'


RESTATE = ('Manager: the user will read this later, with no context. "There are open questions" is not enough. '
           'Write your stop again, in this form. Done: what is finished, one or two lines. Then for each open '
           'question: the problem in plain words, then options A (recommended), B, C, each with what it does and its '
           'cost or risk. Number the questions so the user can answer "1A, 2B". Last line: what else you wait for. '
           'Do not decide the questions yourself.')


def maybe_restate(name, sid, st, a, acted):
    """A session that waits for the user must say what is open and the options (user rule 2026-11-10).
    At most once every 2 h per session, so a session that cannot do better is not nagged."""
    if a['clear'] >= 0.5 or time.time() - st.get('restate_at', 0) < 2 * 3600:
        return
    r = say(name, sid, RESTATE)
    if r in ('sent', 'dry'):
        st['restate_at'] = time.time()
    acted.append(f'sent {name}: open questions not clear -> restate them [{r}]'); log(name, f'auto: asked to restate open questions [{r}]')


def set_tint(name, sid, st, c, acted):
    if c is None:  # Jev call failed: keep the colour
        return
    if c == st.get('tint', 'clear'):
        return
    if DRY:
        acted.append(f'would tint {name}: {c}'); return
    _, out = sh(['agtermctl', 'window', 'list', '--json'])
    try:
        wins = [w['id'] for w in json.loads(out)['result']['windows'] if w.get('open')]
    except Exception:
        wins = []
    rc = 1
    for w in wins:  # the session can be in any open window
        rc, _ = sh(['agtermctl', 'session', 'tint', c] + ([] if c == 'clear' else ['--on', 'icon,name']) + ['--target', sid, '--window', w])  # clear takes no --on
        if rc == 0:
            break
    if rc == 0:
        st['tint'] = c
        acted.append(f'tint {name}: {c}'); log(name, f'auto: tint {c}')


def jev(screen, questions=None, chars=2000):
    key = os.environ.get('TYPESAFE_API_KEY') or next(
        (l.split('=', 1)[1].strip() for l in open(KEYFILE) if l.startswith('TYPESAFE_API_KEY=')), '')
    body = json.dumps({"model": "jev-latest", "state": screen[-chars:], "questions": questions or JEV_Q})
    rc, out = sh(['curl', '-sS', '--fail-with-body', '-m', '30', 'https://api.typesafe.ai/v1/systemone',
                  '-H', f'Authorization: Bearer {key}', '-H', 'Content-Type: application/json',
                  '--data-binary', '@-'], inp=body, timeout=40)
    if rc != 0:
        return None
    return {k: v['noul'] for k, v in json.loads(out)['answers'].items()}


def question_line(screen):
    lines = [l.strip(' │❯') for l in screen.splitlines() if l.strip()]
    for i in range(len(lines) - 1, -1, -1):
        if lines[i].startswith('☐'):
            nxt = lines[i + 1] if i + 1 < len(lines) else ''
            return (lines[i].lstrip('☐ ').strip() + ': ' + nxt)[:180]
    for l in reversed(lines):
        if l.endswith('?') and len(l) > 15:
            return l[:180]
    return 'see the session screen'


# ---------- needs list ----------
def add_need(key, text):
    """Add an (auto) needs line. Returns False when a hand-written line for KEY is already there."""
    p = f'{BRIEFS}/manager-needs.md'
    old = open(p).read().splitlines() if os.path.exists(p) else []
    if any(l.startswith(key + ' |') and not l.endswith('(auto)') for l in old):
        return False
    if DRY:
        return True
    old = [l for l in old if not (l.startswith(key + ' |') and l.endswith('(auto)'))]
    old.append(f'{key} | {text} | (auto)')
    open(p, 'w').write('\n'.join(old) + '\n')
    return True


def drop_auto_needs(key):
    p = f'{BRIEFS}/manager-needs.md'
    if DRY or not os.path.exists(p):
        return
    old = open(p).read().splitlines()
    new = [l for l in old if not (l.startswith(key + ' |') and l.endswith('(auto)'))]
    if new != old:
        open(p, 'w').write('\n'.join(new) + ('\n' if new else ''))


# ---------- GitHub events ----------
def pr_events(e, prev):
    """Fixed messages for PR changes of this ticket's branch. Returns (messages, new pr state)."""
    repo, branch = e.get('REPO'), e.get('BRANCH')
    jira = e.get('JIRA_KEY') or ''
    if not repo or not os.path.isdir(repo) or e.get('KIND') == 'review':
        return [], prev
    fields = '--json number,state,mergeable,headRefOid,mergedAt'
    if branch:
        rc, out = sh(f'cd "{repo}" && gh pr list --state all --head "{branch}" --limit 5 {fields}', timeout=40)
    elif re.fullmatch(r'[A-Z]+-\d+', jira):
        # No BRANCH in the registry: find the PRs by "[KEY-123]" in the title.
        rc, out = sh(f'cd "{repo}" && gh pr list --state all --search "{jira} in:title" --limit 5 {fields}',
                     timeout=40)
    else:
        return [], prev
    if rc != 0:
        return [], prev
    watch = TE.get('MERGE_FOLLOWUP') == 'post-merge-watch'  # project setting in <briefs>/tick.env
    msgs, cur = [], {}
    prs = json.loads(out or '[]')
    for pr in prs:
        n = str(pr['number'])
        cur[n] = f"{pr['state']}/{pr['mergeable']}"
        if pr.get('mergedAt'):
            cur[f'merged_at_{n}'] = pr['mergedAt']
        was = prev.get(n, '')
        if pr['state'] == 'MERGED' and not was.startswith('MERGED'):
            if watch:
                msgs.append((f'/post-merge-watch {os.path.basename(repo)} {n}', f'#{n} merged -> post-merge-watch'))
            elif all(p['state'] in ('MERGED', 'CLOSED') for p in prs) and not open_needs(e['KEY']):
                msgs.append(('/task-cleanup', f'#{n} merged, no open user item -> /task-cleanup'))
            else:
                msgs.append((f'Manager: PR #{n} is merged. Go on with the next step of the plan; do not deploy.',
                             f'#{n} merged -> told to go on'))
            if TE.get('DEPLOY_LIST', 'on') != 'off' and not DRY:
                with open(f'{BRIEFS}/manager-deploys.md', 'a') as f:
                    f.write(f"{e['KEY']} | {os.path.basename(repo)} #{n} merged: run its Deploy steps (PR body)\n")
        elif pr['state'] == 'OPEN' and pr['mergeable'] == 'CONFLICTING' and not was.endswith('CONFLICTING'):
            msgs.append((f'Manager: PR #{n} is CONFLICTING with main. Merge origin/main into the branch, '
                         'resolve, rerun the targeted tests, push, and check mergeable. Do not merge.',
                         f'#{n} CONFLICTING -> told to merge main'))
    return msgs, cur


def recent_merges(e, cur, hours=48):
    """PR numbers in cur merged within the last `hours`."""
    out = set()
    for k, v in cur.items():
        if k.startswith('merged_at_'):
            t = time.mktime(time.strptime(v, '%Y-%m-%dT%H:%M:%SZ')) - time.timezone
            if time.time() - t < hours * 3600:
                out.add(k[len('merged_at_'):])
    return out


def open_needs(key):
    p = f'{BRIEFS}/manager-needs.md'
    return os.path.exists(p) and any(l.startswith(key + ' |') for l in open(p))


# ---------- main ----------
def main():
    if os.path.exists(f'{BRIEFS}/tick.env'):
        TE.update(envfile(f'{BRIEFS}/tick.env'))
    if RUN_ASKS and os.path.exists(f'{BRIEFS}/.ticks-off'):
        print('skip: ticks are off (.ticks-off)'); return 0
    if not DRY:
        try:
            os.mkdir(LOCK)
        except FileExistsError:
            if time.time() - os.path.getmtime(LOCK) < 1200:
                print('skip: BUSY, another tick holds the lock'); return 4
            os.utime(LOCK)
    try:
        return run()
    finally:
        if not DRY:
            try: os.rmdir(LOCK)
            except OSError: pass


DEPLOY_LOG = f'{HOME}/.claude/manager-deploys.log'  # written by scripts/deployed.sh


def main_checkout(repo):
    rc, out = sh(['git', '-C', repo, 'rev-parse', '--path-format=absolute', '--git-common-dir'], timeout=20)
    return os.path.dirname(out.strip()) if rc == 0 and out.strip() else repo


def latest_deploys(tops):
    """{repo main checkout: newest deployed sha}, from deployed.sh lines and <repo>/log/capistrano.log."""
    ev = []  # (when, top, sha)
    if os.path.exists(DEPLOY_LOG):
        for l in open(DEPLOY_LOG):
            f = [x.strip() for x in l.split('|')]
            if len(f) >= 3:
                ev.append((re.sub(r'\D', '', f[0])[:14], f[1], f[2]))
    for top in tops:  # Capistrano logs every deploy on this Mac; reading it touches no server
        c = f'{top}/log/capistrano.log'
        if os.path.exists(c):
            for m in re.finditer(r'Branch \S+ \(at ([0-9a-f]{40})\) deployed as release (\d{14})',
                                 open(c, errors='replace').read()):
                ev.append((m.group(2), top, m.group(1)))  # release id is UTC, close enough for "newest"
    out = {}
    for when, top, sha in sorted(ev):
        if top in tops:
            out[top] = sha
    return out


def handle_deploys(state, envs, watched, acted):
    """A deploy that contains every merged PR of a waiting task session -> /task-cleanup there
    (user rule 2026-11-10). Projects with MERGE_FOLLOWUP=post-merge-watch handle deploys their own way."""
    if TE.get('MERGE_FOLLOWUP') == 'post-merge-watch':
        return
    sessions, sids = state.setdefault('sessions', {}), dict(watched)
    tasks = {k: e for k, e in envs.items() if e.get('KIND', 'task') == 'task' and e.get('REPO')
             and os.path.isdir(e['REPO']) and sids.get(k, '-') != '-'}
    tops = {k: main_checkout(e['REPO']) for k, e in tasks.items()}
    deployed = latest_deploys(set(tops.values()))
    fetched = set()
    for k, e in tasks.items():
        top, st = tops[k], sessions.setdefault(k, {})
        sha = deployed.get(top)
        if not sha or st.get('deploy_checked') == sha or not all_merged(st):
            continue
        if top not in fetched:
            sh(['git', '-C', top, 'fetch', '-q', 'origin'], timeout=60); fetched.add(top)
        nums = [n for n, v in st.get('prs', {}).items() if not n.startswith('merged_at') and v.startswith('MERGED')]
        inside = True
        for n in nums:
            rc, mc = sh(f'cd "{top}" && gh pr view {n} --json mergeCommit -q .mergeCommit.oid', timeout=40)
            if rc != 0 or not mc.strip() or sh(['git', '-C', top, 'merge-base', '--is-ancestor', mc.strip(), sha])[0] != 0:
                inside = False; break
        if not inside:
            st['deploy_checked'] = sha  # look again only after the next deploy
            continue
        # A task can have more PRs than its registry branch (other branches, other repos, drafts):
        # any OPEN PR naming the ticket means the task is not finished.
        jira = e.get('JIRA_KEY') or k
        open_prs = []
        for t in sorted(set(tops.values()) | set(filter(None, TE.get('REPOS', '').split()))):
            rc, out = sh(f'cd "{t}" && gh pr list --state open --search "{jira} in:title" --json number -q ".[].number"', timeout=40)
            open_prs += [f'{os.path.basename(t)}#{x}' for x in out.split()] if rc == 0 else ['?']
        if not open_prs and open_needs(k):
            open_prs = ['an open item on the needs list']
        if open_prs:
            # Its merged work is live, but something is still open: tell it, so it runs the After deploy
            # checks and says what is left. No cleanup.
            r = say(k, sids[k], f'Manager: {os.path.basename(top)} was deployed at {sha[:8]}; it contains your merged '
                    f'PRs. Run their After deploy checks now (read-only; a production step stays the user\'s). Still open: '
                    f'{", ".join(open_prs)}. Then restate what is left for the user.')
            if r in ('sent', 'dry'):
                st['deploy_checked'] = sha
            acted.append(f'sent {k}: deployed in {sha[:8]}, still open ({", ".join(open_prs)}) -> after-deploy checks [{r}]')
            log(k, f'auto: deployed ({sha[:8]}), open: {", ".join(open_prs)} -> after-deploy checks [{r}]')
            continue
        prs = ', '.join('#' + n for n in nums)
        r = say(k, sids[k], f'/task-cleanup deployed: {os.path.basename(top)} {sha[:8]} contains {prs}. '
                'Run the After deploy checks from the PR body first, then finish the cleanup.')
        if r in ('sent', 'dry'):
            st['deploy_checked'] = sha
            if not DRY:
                p = f'{BRIEFS}/manager-deploys.md'
                if os.path.exists(p):
                    keep = [l for l in open(p).read().splitlines() if not l.startswith(k + ' |')]
                    open(p, 'w').write('\n'.join(keep) + ('\n' if keep else ''))
        acted.append(f'sent {k}: deployed in {sha[:8]} -> /task-cleanup [{r}]'); log(k, f'auto: {prs} deployed ({sha[:8]}) -> /task-cleanup [{r}]')


def run():
    state = json.load(open(STATE)) if os.path.exists(STATE) else {}
    sessions = state.setdefault('sessions', {})
    tree = lib('agterm_tree')
    if not tree.strip():
        print('skip: agterm is not answering; nothing read, nothing sent'); return 3
    watched = [l.split('\t') for l in lib('watched_sessions', tree).splitlines() if '\t' in l]
    envs = {}
    for f in os.listdir(BRIEFS):
        if f.endswith('.env'):
            e = envfile(f'{BRIEFS}/{f}')
            if e.get('KEY'):
                envs[e['KEY']] = e
    os.makedirs(ASKDIR, exist_ok=True)
    acted, asks = [], []
    busy = 0  # sessions with live work: run-tick.sh keeps the Mac awake for them
    for name, sid in watched:
        st = sessions.setdefault(name, {})
        if sid == '-':
            if st.get('hash') != 'gone':
                st['hash'] = 'gone'
                # KIND=watch (a session outside the Jira flow, e.g. misc projects): never cleaned up.
                if name in envs and envs[name].get('KIND', 'task') == 'task':
                    asks.append((name, 'session is gone (user closed it): check Jira vs PRs, delete registry'))
            continue
        e = envs.get(name, {'KEY': name})
        # 2. GitHub events (only for registry tickets)
        if name in envs and not RETINT:
            first = 'prs' not in st  # first look: record PR states only, act on later changes
            msgs, st['prs'] = pr_events(e, st.get('prs', {}))
            if first:
                # First look: act only on a merge from the last 48 h that never got its post-merge watch
                # (user rule 2026-11-09: back at a session whose PR is merged -> start post-merge-watch).
                msgs = [m for m in msgs if m[0].startswith('/post-merge-watch')
                        and m[0].split()[-1] in recent_merges(e, st['prs'])]
            done = set(st.setdefault('watch_sent', []))
            msgs = [m for m in msgs if not (m[0].startswith('/post-merge-watch') and m[0] in done)]
            st['watch_sent'] = sorted(done | {m[0] for m in msgs if m[0].startswith('/post-merge-watch')})
            for text, what in msgs:
                r = say(name, sid, text); acted.append(f'sent {name}: {what} [{r}]'); log(name, f'auto: {what} [{r}]')
        # 1. screen
        screen = lib('screen_text', sid)
        tail = '\n'.join(screen.splitlines()[-22:])
        tok = lib('token_of', lib('session_status', tree, sid).strip(), tail).strip()
        if tok == 'working':
            busy += 1
        elif re.search(r'\b\d+ shells?\b', tail):
            # Waiting on a background run. Counts for 3 h from the last screen change, so a
            # forgotten dev server does not hold the Mac awake forever.
            if st.get('shell_tok') != tok:
                st['shell_tok'], st['shell_at'] = tok, time.time()
            if time.time() - st['shell_at'] < 3 * 3600:
                busy += 1
        if st.get('tint') in ('orange', 'blue'):  # retired colours (2026-11-10)
            set_tint(name, sid, st, 'clear', acted)
        if tok == 'working' or (tok == st.get('hash') and not RETINT):
            continue
        if RETINT:  # recolour only: no hash, needs, messages or asks
            a = jev(screen)
            if a:
                fl = [k for k in ('prod', 'money', 'visible', 'down', 'design', 'post') if a[k] >= 0.5]
                w = bool(fl and (a['asks'] >= 0.5 or any(a[k] >= 0.7 for k in ('prod', 'down', 'design'))))
                set_tint(name, sid, st, colour_of(screen), acted)
                if RESTATE_NOW and (w or has_need(name) or a['done'] >= 0.5):
                    maybe_restate(name, sid, st, a, acted)
            continue
        st['hash'] = tok
        drop_auto_needs(name)
        if re.search(r'API Error|Request timed out|overloaded_error|Interrupted by user', '\n'.join(screen.splitlines()[-8:])):
            r = say(name, sid, 'Manager: your last turn stopped on an error. Go on from where you stopped.')
            acted.append(f'sent {name}: stopped on an error -> go on [{r}]'); log(name, f'auto: error stop -> go on [{r}]'); continue
        if re.search(r'ready for review \S+ [0-9a-f]{7,}', tail) or e.get('KIND') == 'review':
            asks.append((name, 'review flow (ready for review / review session idle)', screen)); continue
        # 3. Jev
        a = jev(screen)
        if a is None:
            asks.append((name, 'Jev call failed', screen)); continue
        # A post-release watch must run through the post-merge-watch skill (user rule 2026-11-09).
        if a['postwatch'] >= 0.6 and a['pmwskill'] < 0.5 and not st.get('pmw_nudged'):
            st['pmw_nudged'] = True
            r = say(name, sid, 'Manager: you are watching production after a merge. Do it with the post-merge-watch '
                    'skill: run /post-merge-watch <repo> <PR number> and go on from its checkpoints.')
            acted.append(f'sent {name}: post-release watch without the skill -> /post-merge-watch [{r}]')
            log(name, f'auto: post-release watch without the skill -> /post-merge-watch [{r}]')
        flags = [k for k in ('prod', 'money', 'visible', 'down', 'design', 'post') if a[k] >= 0.5]
        # A strong production / down-server / design signal waits for the user even without a "?"
        # (2026-11-06: "run the prod read-only EXPLAIN with your env file", no question mark).
        strong = any(a[k] >= 0.7 for k in ('prod', 'down', 'design'))
        waits = bool(flags and (a['asks'] >= 0.5 or strong))
        set_tint(name, sid, st, colour_of(screen), acted)
        if waits or (a['asks'] < 0.5 and a['done'] >= 0.5):
            maybe_restate(name, sid, st, a, acted)
        if waits:
            q = question_line(screen)
            if add_need(name, f"waits for you ({','.join(flags)}): {q}"):
                acted.append(f"needs {name}: {','.join(flags)}: {q[:90]}"); log(name, f"auto: needs line ({','.join(flags)}): {q[:120]}")
            else:
                log(name, f"auto: waits for the user ({','.join(flags)}); already on the needs list")
        elif a['asks'] < 0.5 and a['done'] >= 0.5:
            log(name, 'auto: finished, waits for the user; nothing sent')
        else:
            why = 'question, no user-only flag' if a['asks'] >= 0.5 else 'idle, not finished'
            asks.append((name, why, screen))
    if not RETINT:
        handle_deploys(state, envs, watched, acted)
    # holds: Claude starts held tasks; only ask when the file changed or once an hour
    hp = f'{BRIEFS}/manager-holds.md'
    # Lines that wait for the user ("needs user", "user decides") are not the manager's to start.
    ready = [l for l in (open(hp).read().splitlines() if os.path.exists(hp) else [])
             if l.strip() and not re.search(r'needs user|user decides|user\'s', l, re.I)]
    if ready:
        hh = hashlib.sha1('\n'.join(ready).encode()).hexdigest()[:12]
        if hh != state.get('holds') or time.time() - state.get('holds_t', 0) > 3600:
            state['holds'], state['holds_t'] = hh, time.time()
            asks.append(('holds', 'check the start conditions of these held tasks', '\n'.join(ready)))
    # print
    for line in acted:
        print(line)
    for item in asks:
        name, why = item[0], item[1]
        f = f"{ASKDIR}/{re.sub(r'[^A-Za-z0-9_-]', '_', name)}.txt"
        if not DRY:
            body = item[2] if len(item) > 2 else ''
            open(f, 'w').write(f'# {name} - {why}\n' + '\n'.join(body.splitlines()[-40:]) + '\n')
        if RUN_ASKS and not DRY:
            live = sum(1 for _, sid in watched if sid != '-')
            res = run_ask(state, name, f, live)
            if res == 'deferred':  # over the per-hour limit: look again at a later tick
                sessions.get(name, {}).pop('hash', None)
            print(f'ASK {name} - {why} -> {res}')
        else:
            print(f'ASK {name} {f} - {why}')
    idle = state.get('idle', 0) + 1 if not acted and not asks else 0
    if not DRY:
        state['idle'] = idle
        json.dump(state, open(STATE, 'w'), indent=1)
    if busy or acted or asks:
        print(f'awake: {busy} working, {len(acted)} sent, {len(asks)} asks')
    if not acted and not asks:
        print(f'skip: no change ({idle} in a row)')
        if idle >= IDLE_STOP and not RUN_ASKS:
            print('IDLE: stop the ticks (CronDelete) until the user writes')
    return 10 if asks else 0


# ---------- ASK items: one small Claude call each, with limits ----------
LIMITS_FILE = f'{BRIEFS}/tick-limits.env'
LIMIT_DEFAULTS = {
    'PER_SESSION_HOUR': 2,       # more in one hour -> deferred to a later tick (no alarm)
    'PER_SESSION_DAY': 12,       # more in one day -> that session looks stuck in a loop: alarm
    'TOTAL_DAY_MIN': 30,         # whole manager per day, at least this many Claude calls
    'TOTAL_DAY_PER_SESSION': 6,  # ... or this many per live watched session, if that is more
}
USAGE = f'{BRIEFS}/ticks-usage.log'
CLAUDE = os.environ.get('CLAUDE_BIN') or shutil.which('claude') or f'{HOME}/.local/bin/claude'


def limits():
    d = dict(LIMIT_DEFAULTS)
    if os.path.exists(LIMITS_FILE):
        for k, v in envfile(LIMITS_FILE).items():
            if k in d and v.isdigit():
                d[k] = int(v)
    return d


def alarm(state, reason, detail):
    """Once per day and reason: desktop notification + a message the manager session must ask about."""
    day = datetime.now().strftime('%Y-%m-%d')
    seen = state.setdefault('alarms', {})
    if seen.get(reason) == day:
        return
    seen[reason] = day
    log('manager', f'LIMIT: {reason} - {detail}')
    add_need('LIMIT', f'tick limit hit ({reason}): {detail} | raise / keep / ticks off')
    sh(['agtermctl', 'notify', f'Tick limit hit: {reason}. {detail}', '--title', 'Manager: decide'])
    # The question opens as an html-ask overlay in the manager's own agterm session (red, blocked
    # mark, waits for the user). status_ask.py applies the answer itself: no Claude turn needed.
    msf = f'{BRIEFS}/.manager-session'
    sid = open(msf).read().strip() if os.path.exists(msf) else ''
    if sid:
        env = dict(os.environ, AGTERM_ENABLED='1', AGTERM_SESSION_ID=sid, MANAGER_SESSION=sid)
        subprocess.Popen(['python3', f'{SCRIPTS}/status_ask.py', '--mode', 'limit', '--reason',
                          f'{reason}: {detail}'], env=env, stdin=subprocess.DEVNULL,
                         stdout=open(f'{BRIEFS}/.status-answer.log', 'a'), stderr=subprocess.STDOUT,
                         start_new_session=True)


def system_prompt():
    """rules.md, then the project's own rules (<PROJECT_DIR>/.claude/manager/project.md), which win."""
    text = open(f'{HOME}/.claude/skills/manager/rules.md').read()
    proj = os.path.join(TE.get('PROJECT_DIR', ''), '.claude/manager/project.md')
    if TE.get('PROJECT_DIR') and os.path.exists(proj):
        text += '\n\n# Project rules (they win over the page above)\n\n' + open(proj).read()
    return text


def run_ask(state, name, f, live):
    lim = limits()
    now = time.time()
    hist = [h for h in state.get('ask_hist', []) if now - h[0] < 86400]
    state['ask_hist'] = hist
    total_cap = max(lim['TOTAL_DAY_MIN'], lim['TOTAL_DAY_PER_SESSION'] * live)
    mine = [h for h in hist if h[1] == name]
    if len(hist) >= total_cap:
        alarm(state, 'day total', f'{len(hist)} Claude calls in 24 h (cap {total_cap}); ASK items wait')
        return 'deferred (day total cap)'
    if len(mine) >= lim['PER_SESSION_DAY']:
        alarm(state, f'{name} per day', f'{name} needed Claude {len(mine)} times in 24 h (cap '
              f"{lim['PER_SESSION_DAY']}): it may be stuck in a loop")
        return 'skipped (session day cap)'
    if sum(1 for h in mine if now - h[0] < 3600) >= lim['PER_SESSION_HOUR']:
        return 'deferred'
    hist.append([now, name])
    prompt = (f'You are the manager tick helper. MANAGER_BRIEFS={BRIEFS} (export it before every '
              f'say.sh call). Handle this ONE item now, as the system prompt says: answer the session '
              f'with say.sh, or add a needs line with `python3 {SCRIPTS}/autotick.py --add-need KEY "text"`. '
              f'Do not write the log (the script does). Then reply in ONE line: what you did.\n\nASK item ({f}):\n' + open(f).read())
    env, cwd = dict(os.environ, MANAGER_BRIEFS=BRIEFS), BRIEFS
    # The Claude account of this manager: <briefs>/tick.env CLAUDE_CONFIG_DIR (a project can run on
    # another account). Without it the call bills the default account. The login is stored per
    # config-dir string: a relative dir works only from the folder that holds it (CLAUDE_CWD).
    if 'CLAUDE_CONFIG_DIR' in TE:
        env['CLAUDE_CONFIG_DIR'] = TE['CLAUDE_CONFIG_DIR']
    cwd = TE.get('CLAUDE_CWD', cwd)
    try:
        r = subprocess.run([CLAUDE, '-p', prompt, '--disable-slash-commands', '--strict-mcp-config',
                            '--tools', 'Bash,Read,Edit', '--allowedTools', 'Bash', 'Read', 'Edit',
                            '--system-prompt', system_prompt(),
                            '--output-format', 'json', '--no-session-persistence'],
                           capture_output=True, text=True, timeout=600, cwd=cwd, env=env,
                           stdin=subprocess.DEVNULL)
        j = json.loads(r.stdout)
    except Exception as ex:  # noqa: BLE001 - any failure is reported, never retried in a loop
        log(name, f'ASK: claude call failed: {ex!s:.120}')
        return 'claude call failed'
    u = j.get('usage', {})
    w = int(u.get('cache_creation_input_tokens', 0) * 1.25 + u.get('cache_read_input_tokens', 0) * 0.1
            + u.get('output_tokens', 0) * 5 + u.get('input_tokens', 0))
    res = (j.get('result') or '').strip().replace('\n', ' ')[:200]
    with open(USAGE, 'a') as fh:
        fh.write(f"{NOW} | {name} | weighted {w} | account {env.get('CLAUDE_CONFIG_DIR', 'default')} | read {u.get('cache_read_input_tokens', 0)} | write "
                 f"{u.get('cache_creation_input_tokens', 0)} | out {u.get('output_tokens', 0)} | {res}\n")
    log(name, f'ASK -> claude ({w // 1000}k): {res[:160]}')
    return res or 'done'


if __name__ == '__main__':
    if '--add-need' in sys.argv:  # used by the small Claude call for an ASK item
        i = sys.argv.index('--add-need'); add_need(sys.argv[i + 1], sys.argv[i + 2]); sys.exit(0)
    if '--reset-idle' in sys.argv:  # tick.sh reset (manager start): the idle count starts at 0
        if os.path.exists(STATE):
            st = json.load(open(STATE)); st['idle'] = 0; json.dump(st, open(STATE, 'w'), indent=1)
        sys.exit(0)
    sys.exit(main())
