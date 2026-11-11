#!/usr/bin/env python3
"""Ask Jev which model should implement a plan (or part of it).

    pick-model.py <plan-file> [--scope "Tasks 3-6"]

Prints one line:  <choice> <model> <effort>  scores=...   (choice: self | haiku | sonnet | opus)
  self   = so small that a second agent costs more than doing it: the coordinator does it itself
  haiku / sonnet / opus = start an executor with that model (start-executor.sh)
Jev unreachable -> "sonnet" with reason=jev-failed. The coordinator may overrule it and says why.
"""
import json, os, subprocess, sys

HOME = os.path.expanduser('~')
KEYFILE = f'{HOME}/.config/typesafe/.env'
EFFORT = {'self': '-', 'haiku': '-', 'sonnet': 'medium', 'opus': 'high'}


def N(q):
    return {"type": "noul", "instructions": q}


Q = {
    'self': N("Could a developer finish the whole change in under 15 minutes: a few lines in one or two "
              "files, no new logic, at most one small test?"),
    'haiku': N("Is the work routine and fully specified: the plan names each file and the exact change, "
               "so a junior developer could do it without making any design decision?"),
    'sonnet': N("Is this normal product engineering for a mid-level developer: new code and tests across "
                "several files, following existing patterns, with the design settled by the plan?"),
    'opus': N("Would only a senior engineer get this right: hard concurrency or locking, risky migrations "
              "or backfills of production data, money or security logic, tricky algorithms or "
              "performance tuning, or a design that the plan still leaves unclear?"),
}

def main():
    if len(sys.argv) < 2 or not os.path.isfile(sys.argv[1]):
        sys.exit('usage: pick-model.py <plan-file> [--scope "Tasks 3-6"]')
    text = open(sys.argv[1], errors='replace').read()
    if '--scope' in sys.argv:
        text = f"SCOPE TO IMPLEMENT NOW: {sys.argv[sys.argv.index('--scope') + 1]}\n\n" + text
    key = os.environ.get('TYPESAFE_API_KEY') or next(
        (l.split('=', 1)[1].strip() for l in open(KEYFILE) if l.startswith('TYPESAFE_API_KEY=')), '')
    body = json.dumps({"model": "jev-latest", "state": text[:14000], "questions": Q})
    r = subprocess.run(['curl', '-sS', '--fail-with-body', '-m', '40', 'https://api.typesafe.ai/v1/systemone',
                        '-H', f'Authorization: Bearer {key}', '-H', 'Content-Type: application/json',
                        '--data-binary', '@-'], input=body, capture_output=True, text=True, timeout=50)
    try:
        a = {k: v['noul'] for k, v in json.loads(r.stdout)['answers'].items()}
    except Exception:  # noqa: BLE001
        print('sonnet sonnet medium reason=jev-failed')
        return
    # The cheapest level that clearly fits wins; opus only with a clear margin over sonnet.
    if a['self'] >= 0.6:
        c = 'self'
    elif a['opus'] >= 0.6 and a['opus'] - a['sonnet'] >= 0.15:
        c = 'opus'
    elif a['haiku'] >= 0.6 and a['haiku'] >= a['sonnet'] - 0.1:
        c = 'haiku'
    else:
        c = 'sonnet'
    scores = ' '.join(f'{k}={a[k]:.2f}' for k in Q)
    print(f'{c} {"-" if c == "self" else c} {EFFORT[c]} scores: {scores}')


if __name__ == '__main__':
    main()
