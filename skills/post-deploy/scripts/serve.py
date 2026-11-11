#!/usr/bin/env python3
"""Serve the post-deploy checklist on 127.0.0.1 and keep the ticks in checks.json.

    serve.py [PORT]        (default 47312)

GET /        the page          GET /data   data.json + checks
POST /check  {"id": "...", "on": true|false}
Runs in the agterm session "Post-deploy steps" (open.sh starts it). Ctrl-C stops it.
"""
import json, os, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOME = os.path.expanduser('~')
DIR = os.environ.get('POST_DEPLOY_DIR', f'{HOME}/.claude/post-deploy')
DATA, CHECKS = f'{DIR}/data.json', f'{DIR}/checks.json'
PAGE = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'page.html')
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 47312
LOCK = threading.Lock()


def load(path, default):
    try:
        return json.load(open(path))
    except Exception:  # noqa: BLE001
        return default


class H(BaseHTTPRequestHandler):
    def send(self, code, body, ctype='application/json'):
        b = body if isinstance(body, bytes) else body.encode()
        self.send_response(code)
        self.send_header('Content-Type', ctype + '; charset=utf-8')
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        if self.path in ('/', '/index.html'):
            return self.send(200, open(PAGE, 'rb').read(), 'text/html')
        if self.path.startswith('/data'):
            d = load(DATA, {'prs': [], 'version': '-'})
            d['checks'] = load(CHECKS, {})
            return self.send(200, json.dumps(d))
        self.send(404, '{}')

    def do_POST(self):
        if self.path != '/check':
            return self.send(404, '{}')
        try:
            req = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))))
            iid = str(req['id'])[:80]
        except Exception:  # noqa: BLE001
            return self.send(400, '{}')
        with LOCK:
            c = load(CHECKS, {})
            if req.get('on'):
                c[iid] = time.strftime('%Y-%m-%d %H:%M')
            else:
                c.pop(iid, None)
            tmp = CHECKS + '.tmp'
            json.dump(c, open(tmp, 'w'), indent=1)
            os.replace(tmp, CHECKS)
        print(time.strftime('%H:%M'), 'checked' if req.get('on') else 'unchecked', iid, flush=True)
        self.send(200, '{"ok":true}')

    def log_message(self, *a):
        pass


if __name__ == '__main__':
    os.makedirs(DIR, exist_ok=True)
    print(f'Post-deploy checklist on http://127.0.0.1:{PORT}/  (Ctrl-C stops it)', flush=True)
    ThreadingHTTPServer(('127.0.0.1', PORT), H).serve_forever()
