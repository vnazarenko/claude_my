#!/usr/bin/env python3
"""Show the manager's status as an html-ask overlay, ask one question, apply the answer.

    status_ask.py [--mode status|limit] [--reason "<text>"] [--dry]

status: ticks, Claude calls and tokens in the last 24 h, limits, sessions, the needs list, for both
        managers (~/.claude/task-briefs and every ~/.claude/task-briefs-<project>). Question: keep,
        turn ticks off, turn ticks on.
limit:  the same page, opened because autotick.py hit a limit (--reason). Question: raise the
        limits x2 / keep them / turn ticks off.

The manager session runs it with Bash run_in_background (the overlay waits for the user). It applies
the answer itself (limits file, .ticks-off) and prints one line. --dry writes the page and prints its
path without opening it.
"""
import html, json, os, re, subprocess, sys, time
from datetime import datetime, timedelta

HOME = os.path.expanduser('~')
import glob
MANAGERS = [('Main', f'{HOME}/.claude/task-briefs')] + [
    (os.path.basename(d)[len('task-briefs-'):].capitalize(), d)
    for d in sorted(glob.glob(f'{HOME}/.claude/task-briefs-*')) if os.path.isdir(d)]
TICKLOG = f'{HOME}/Library/Logs/manager-tick.log'
HTMLASK = f'{HOME}/.claude/skills/html-ask/scripts'
OUTDIR = f'{HOME}/.claude/task-briefs/.status-page'
E = html.escape
args = sys.argv[1:]
mode = args[args.index('--mode') + 1] if '--mode' in args else 'status'
reason = args[args.index('--reason') + 1] if '--reason' in args else ''
since = datetime.now() - timedelta(hours=24)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


def limits_of(b):
    d = {'PER_SESSION_HOUR': 2, 'PER_SESSION_DAY': 12, 'TOTAL_DAY_MIN': 30, 'TOTAL_DAY_PER_SESSION': 6}
    p = f'{b}/tick-limits.env'
    if os.path.exists(p):
        for l in open(p):
            k, _, v = l.strip().partition('=')
            if k in d and v.isdigit():
                d[k] = int(v)
    return d


def ts(line):
    m = re.match(r'(\d{4}-\d\d-\d\d \d\d:\d\d)', line)
    return datetime.strptime(m.group(1), '%Y-%m-%d %H:%M') if m else None


def account(b):
    """The Claude account a manager's tick calls use: <briefs>/tick.env CLAUDE_CONFIG_DIR, else default."""
    cfg = ''
    if os.path.exists(f'{b}/tick.env'):
        for l in open(f'{b}/tick.env'):
            if l.startswith('CLAUDE_CONFIG_DIR='):
                cfg = l.split('=', 1)[1].strip()
    cwd = next((l.split('=', 1)[1].strip() for l in open(f'{b}/tick.env') if l.startswith('CLAUDE_CWD=')), '') \
        if os.path.exists(f'{b}/tick.env') else ''
    if cfg and not cfg.startswith('/'):
        cfg = os.path.join(cwd or HOME, cfg)
    p = f'{cfg}/.claude.json' if cfg else f'{HOME}/.claude.json'
    try:
        a = json.load(open(p)).get('oauthAccount') or {}
        plan = {'claude_max': 'Max', 'claude_team': 'Team', 'claude_pro': 'Pro'}.get(a.get('organizationType'), a.get('organizationType', '?'))
        return f"{a.get('emailAddress', '?')} · {plan}"
    except Exception:
        return f'unknown ({p})'


def stats(name, b):
    s = {'name': name, 'off': os.path.exists(f'{b}/.ticks-off'), 'lim': limits_of(b), 'acct': account(b)}
    base = os.path.basename(b)
    s['ticks'] = sum(1 for l in (open(TICKLOG) if os.path.exists(TICKLOG) else [])
                     if l.endswith(f' {base}\n') and (ts(l) or since) > since)
    calls, tok = [], 0
    if os.path.exists(f'{b}/ticks-usage.log'):
        for l in open(f'{b}/ticks-usage.log'):
            t = ts(l)
            if t and t > since:
                p = [x.strip() for x in l.split('|')]
                w = int(re.sub(r'\D', '', p[2]) or 0)
                calls.append((p[0][11:16], p[1], w, p[-1])); tok += w
    s['calls'], s['tok'] = calls, tok
    st = json.load(open(f'{b}/.auto-state.json')) if os.path.exists(f'{b}/.auto-state.json') else {}
    live = sum(1 for v in st.get('sessions', {}).values() if v.get('hash') != 'gone')
    s['cap'] = max(s['lim']['TOTAL_DAY_MIN'], s['lim']['TOTAL_DAY_PER_SESSION'] * live)
    last = {}
    if os.path.exists(f'{b}/manager-log.md'):
        for l in open(f'{b}/manager-log.md'):
            p = [x.strip() for x in l.split('|', 2)]
            if len(p) == 3:
                last[p[1]] = (p[0][5:], p[2])
    s['sessions'] = [(k, 'gone' if v.get('hash') == 'gone' else 'live', last.get(k, ('', ''))) for k, v in
                     sorted(st.get('sessions', {}).items())]
    s['auto'] = sum(1 for l in (open(f'{b}/manager-log.md') if os.path.exists(f'{b}/manager-log.md') else [])
                    if ' auto: ' in l and (ts(l) or since) > since)
    s['needs'] = [l.strip() for l in (open(f'{b}/manager-needs.md') if os.path.exists(f'{b}/manager-needs.md') else [])
                  if l.strip() and not l.startswith('#')]
    return s


def bar(n, cap):
    pct = min(100, int(100 * n / cap)) if cap else 0
    cls = 'hot' if pct >= 80 else ''
    return f'<div class="bar {cls}"><i style="width:{pct}%"></i></div><small>{n} of {cap}</small>'


def manager_block(s):
    rows = ''.join(f'<tr><td>{E(k)}</td><td class="{st}">{st}</td><td>{E(t)}</td><td>{E(w[:150])}</td></tr>'
                   for k, st, (t, w) in s['sessions'])
    calls = ''.join(f'<tr><td>{E(t)}</td><td>{E(k)}</td><td>{w // 1000}k</td><td>{E(r[:140])}</td></tr>'
                    for t, k, w, r in s['calls'][-8:]) or '<tr><td colspan=4>none</td></tr>'
    needs = ''.join(f'<li>{E(n[:220])}</li>' for n in s['needs'][:12]) or '<li>nothing</li>'
    more = f'<li>… {len(s["needs"]) - 12} more</li>' if len(s['needs']) > 12 else ''
    return f'''
<section class="mgr">
  <h2>{E(s["name"])} manager · ticks <b class="{"offc" if s["off"] else "onc"}">{"OFF" if s["off"] else "ON"}</b>
    <span class="acct">Claude account: {E(s["acct"])}</span></h2>
  <div class="stats">
    <div><b>{s["ticks"]}</b><small>ticks, 24 h</small></div>
    <div><b>{len(s["calls"])}</b><small>Claude calls, 24 h</small>{bar(len(s["calls"]), s["cap"])}</div>
    <div><b>{s["tok"] // 1000}k</b><small>weighted tokens, 24 h</small></div>
    <div><b>{s["auto"]}</b><small>actions with no Claude</small></div>
    <div><b>{len(s["needs"])}</b><small>items wait for you</small></div>
  </div>
  <details><summary>Last Claude calls</summary><table>{calls}</table></details>
  <details><summary>Waits for you</summary><ul>{needs}{more}</ul></details>
  <details><summary>Sessions ({len(s["sessions"])})</summary><table>{rows}</table></details>
</section>'''


def page(all_stats):
    lim = all_stats[0]['lim']
    if mode == 'limit':
        kicker, h1 = 'Manager · tick limit hit', 'A tick limit was hit. What next?'
        ctx = (f'<b class="hotc">{E(reason) or "A limit was hit."}</b><br>Ticks keep running; only the '
               'Claude calls that are over the limit wait. Before this change one tick cost ~150k tokens; '
               'now a tick with no question costs 0 and one question ~20-30k.')
        opts = [('raise', 'Raise the limits x2', 'Double the day limits for both managers. Claude calls go on now.',
                 ['Work does not stop'], ['Up to 2x more tokens today']),
                ('keep', 'Keep the limits', 'The calls over the limit wait until tomorrow (24 h window).',
                 ['Token use stays capped'], ['Sessions may wait for an answer']),
                ('off', 'Turn ticks off', 'Both managers stop ticking until you turn them on.',
                 ['0 tokens'], ['No session gets answers or pushes'])]
    else:
        kicker, h1 = 'Manager · status', 'Manager status, last 24 hours'
        ctx = ('Ticks run from launchd every 15 min. A tick with no question costs 0 Claude tokens; '
               'a question costs one small Claude call (~20-30k weighted). Day limit per manager: '
               f'max({lim["TOTAL_DAY_MIN"]}, {lim["TOTAL_DAY_PER_SESSION"]} x live sessions) calls; '
               f'per session {lim["PER_SESSION_DAY"]} a day, {lim["PER_SESSION_HOUR"]} an hour.')
        opts = [('ok', 'OK, keep going', 'Change nothing.', [], []),
                ('on', 'Turn ticks ON', 'Both managers tick every 15 min.', [], []),
                ('off', 'Turn ticks OFF', 'Both managers stop until you turn them on.', [], [])]
    cards = ''
    for i, (oid, title, line, pros, cons) in enumerate(opts):
        badge = ' <span class="badge">Recommended</span>' if i == 0 else ''
        pc = (f'<div class="pc"><div class="pro"><b>Pros</b><ul>{"".join(f"<li>{E(p)}</li>" for p in pros)}</ul></div>'
              f'<div class="con"><b>Cons</b><ul>{"".join(f"<li>{E(c)}</li>" for c in cons)}</ul></div></div>') if pros else ''
        cards += (f'<section class="opt" data-id="{oid}"><h2>{E(title)}{badge}</h2><p>{E(line)}</p>{pc}'
                  f'<div class="go"><button type="button" class="primary single-only pick">{E(title)}</button></div></section>\n')
    style = '''<style>
.mgr{border:1px solid var(--line);border-radius:8px;padding:10px 14px;margin:0 0 14px}
.mgr h2{font-size:15px;margin:0 0 8px}.acct{font-weight:400;font-size:12px;color:var(--muted);margin-left:12px}.onc{color:#3fb950}.offc,.hotc{color:#f85149}
.stats{display:grid;grid-template-columns:repeat(5,1fr);gap:10px;margin-bottom:6px}
.stats div{display:flex;flex-direction:column}.stats b{font-size:22px}.stats small{color:var(--muted)}
.bar{height:6px;background:var(--line);border-radius:3px;margin-top:4px}.bar i{display:block;height:6px;border-radius:3px;background:var(--accent)}
.bar.hot i{background:#f85149}
details{margin:4px 0}summary{cursor:pointer;color:var(--muted)}
table{border-collapse:collapse;width:100%;font-size:12px}td{padding:2px 6px;border-bottom:1px solid var(--line);vertical-align:top}
td.gone{color:var(--muted)}td.live{color:#3fb950}
</style>'''
    return (f'<body data-mode="single">\n{style}\n<div class="wrap">\n<div class="kicker">{E(kicker)}</div>\n'
            f'<h1>{E(h1)}</h1>\n<div class="context">{ctx}</div>\n'
            + ''.join(manager_block(s) for s in all_stats)
            + f'<div class="opts">\n{cards}</div>\n'
            '''<div class="foot">
    <div>
      <textarea id="notes" placeholder="Notes, or your own answer (for example: set the day limit to 50)"></textarea>
      <div class="hint single-only">Click a card's button to answer. Notes go with it.</div>
      <div class="hint multi-only">Click cards to select several, then Submit.</div>
    </div>
    <div class="btns">
      <button type="button" data-agterm="session.overlay.close">Cancel</button>
      <button type="button" id="other">Send notes only</button>
      <button type="button" class="primary multi-only" id="submit">Submit</button>
    </div>
  </div>
</div>''')


def apply(choice):
    if choice == 'raise':
        for _, b in MANAGERS:
            lim = limits_of(b)
            lim['TOTAL_DAY_MIN'] *= 2; lim['TOTAL_DAY_PER_SESSION'] *= 2; lim['PER_SESSION_DAY'] *= 2
            open(f'{b}/tick-limits.env', 'w').write(''.join(f'{k}={v}\n' for k, v in lim.items()))
        return 'limits doubled for both managers'
    if choice in ('off', 'on'):
        for _, b in MANAGERS:
            p = f'{b}/.ticks-off'
            if choice == 'off':
                open(p, 'a').close()
            elif os.path.exists(p):
                os.remove(p)
        return f'ticks turned {choice.upper()} for both managers'
    return 'nothing changed'


def main():
    os.makedirs(OUTDIR, exist_ok=True)
    body, out = f'{OUTDIR}/{mode}.body.html', f'{OUTDIR}/{mode}.html'
    open(body, 'w').write(page([stats(n, b) for n, b in MANAGERS if os.path.isdir(b)]))
    subprocess.run(['python3', f'{HTMLASK}/build.py', body, out, 'Manager status'], check=True,
                   capture_output=True)
    if '--dry' in args:
        print(out); return 0
    r = subprocess.run(['bash', f'{HTMLASK}/ask.sh', out], capture_output=True, text=True)
    try:
        v = json.loads(json.loads(r.stdout.strip().splitlines()[-1])['value'])
    except Exception:  # dismissed, unavailable or empty
        print(f'no answer (exit {r.returncode}): {r.stdout.strip()[:200]}'); return 2
    choice = (v.get('choice') or [None])[0]
    notes = v.get('notes') or v.get('other') or ''
    done = apply(choice)
    ms = os.environ.get('MANAGER_SESSION')
    if notes and ms:  # free text ("set the day limit to 50"): the manager session applies it
        subprocess.run(['bash', f'{os.path.dirname(os.path.abspath(__file__))}/say.sh', ms,
                        f'Manager: the user answered the tick status page: choice={choice}, notes: {notes}. '
                        f'Already done: {done}. Apply the notes (limits are in <briefs>/tick-limits.env).'])
    print(f'user chose: {choice or "notes only"}; {done}' + (f'; notes: {notes}' if notes else ''))
    return 0


if __name__ == '__main__':
    sys.exit(main())
