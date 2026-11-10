#!/usr/bin/env python3
"""Keep the Mac awake for 30 more minutes (run-tick.sh calls this when a tick saw live work).

Rolling hold: each busy tick (every 15 min) replaces the caffeinate, so the Mac can sleep again
about 30 min after the last busy tick, or at once when ticks stop. Own process group, because
launchd kills what is left in the job's group when run-tick.sh exits.
Not on battery below 20%. A closed lid is not covered: macOS sleeps anyway.
"""
import os, re, subprocess, sys
PID = os.path.expanduser('~/.claude/task-briefs/.caffeinate.pid')
HOLD = '1800'

def low_battery():
    out = subprocess.run(['pmset', '-g', 'batt'], capture_output=True, text=True).stdout
    m = re.search(r'(\d+)%', out)
    return "'Battery Power'" in out and m and int(m.group(1)) < 20

def old_pid():
    try:
        pid = int(open(PID).read().strip())
        cmd = subprocess.run(['ps', '-o', 'command=', '-p', str(pid)], capture_output=True, text=True).stdout
        return pid if cmd.startswith('caffeinate') else None
    except (OSError, ValueError):
        return None

def main():
    old = old_pid()
    if low_battery():
        print('keep-awake: battery below 20%, not holding'); return 0
    new = subprocess.Popen(['caffeinate', '-i', '-s', '-t', HOLD], start_new_session=True,
                           stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    open(PID, 'w').write(str(new.pid))
    if old:
        try:
            os.kill(old, 15)
        except OSError:
            pass
    print(f'keep-awake: held for {HOLD}s (pid {new.pid})')
    return 0

sys.exit(main())
