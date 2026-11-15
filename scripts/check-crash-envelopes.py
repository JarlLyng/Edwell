#!/usr/bin/env python3
"""Checks what Edwell's crash reports send, against a stand-in for Sentry on this Mac (#51).

    SENTRY_DSN=http://0123456789abcdef0123456789abcdef@127.0.0.1:8969/1 ./build.sh
    python3 -I scripts/check-crash-envelopes.py build/Edwell.app

Listens on the port in the build's DSN (on 127.0.0.1 only; it refuses a build whose DSN is a real one)
the way Sentry's ingest does, runs `Edwell --send-test-report` (one session
and one message, no window, so the user's autosave is never touched) and reads every envelope that
arrives. It passes when the session's `did` and the event's user are the shared `anonymous`, the event
has no `device_app_hash` and no device ID, and neither the home folder nor the account name appears in
anything sent. Run it before every sentry-cocoa upgrade: the `did` depends on an SDK detail.
Afterwards build again without SENTRY_DSN, so the local DSN doesn't stay in build/Edwell.app.
"""

import getpass
import gzip
import http.server
import json
import os
import plistlib
import subprocess
import sys
import threading
import time
import zlib
from urllib.parse import urlparse

bodies = []


class Ingest(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        encoding = self.headers.get("Content-Encoding", "")
        if encoding == "gzip":
            body = gzip.decompress(body)
        elif encoding == "deflate":
            body = zlib.decompress(body)
        bodies.append(body)
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, *args):
        pass


def items(body):
    """An envelope: a header line, then for each item a header line and a payload."""
    lines = body.split(b"\n")
    index = 1
    while index < len(lines):
        if not lines[index].strip():
            index += 1
            continue
        header = json.loads(lines[index])
        index += 1
        payload = lines[index] if index < len(lines) else b""
        index += 1
        yield header.get("type"), payload


def main():
    app = sys.argv[1] if len(sys.argv) > 1 else "build/Edwell.app"
    executable = os.path.join(app, "Contents", "MacOS", "Edwell")
    with open(os.path.join(app, "Contents", "Info.plist"), "rb") as f:
        dsn = urlparse(plistlib.load(f).get("SentryDSN", ""))
    if dsn.hostname not in ("127.0.0.1", "localhost") or not dsn.port:
        sys.exit("This build's DSN isn't a local one (http://<key>@127.0.0.1:<port>/1), so nothing was run.")
    server = http.server.ThreadingHTTPServer(("127.0.0.1", dsn.port), Ingest)
    threading.Thread(target=server.serve_forever, daemon=True).start()

    run = subprocess.run([executable, "--send-test-report"], capture_output=True, text=True, timeout=120)
    print(run.stdout.strip())
    time.sleep(2)
    server.shutdown()

    failures = []
    events, sessions = [], []
    for body in bodies:
        for kind, payload in items(body):
            try:
                data = json.loads(payload)
            except ValueError:
                continue
            if kind == "event":
                events.append(data)
            elif kind == "session":
                sessions.append(data)

    if not events:
        failures.append("no event arrived")
    if not sessions:
        failures.append("no session arrived")
    for session in sessions:
        print("session:", json.dumps({k: session.get(k) for k in ("did", "status", "init", "attrs")}))
        if session.get("did") != "anonymous":
            failures.append(f"session did is {session.get('did')!r}")
    for event in events:
        contexts = event.get("contexts", {})
        print("event user:", json.dumps(event.get("user")), "environment:", event.get("environment"))
        print("event message:", (event.get("message") or {}).get("formatted"))
        print("event contexts:", json.dumps({name: sorted(value) for name, value in contexts.items()
                                              if isinstance(value, dict)}))
        if event.get("user") != {"id": "anonymous"}:
            failures.append(f"event user is {event.get('user')!r}")
        if "device_app_hash" in contexts.get("app", {}):
            failures.append("device_app_hash was sent")
        if "id" in contexts.get("device", {}):
            failures.append("a device id was sent")
        if "server_name" in event:
            failures.append("server_name was sent")
        if "<path>" not in json.dumps((event.get("message") or {}).get("formatted")):
            failures.append("the test message's path wasn't redacted")

    sent = b"\n".join(bodies).decode("utf-8", "replace")
    home = os.path.expanduser("~")
    user = getpass.getuser()
    for secret, name in [(home, "the home folder"), (user, "the account name")]:
        if secret and secret in sent:
            failures.append(f"{name} appears in what was sent")

    if failures:
        print("FAILED:\n  " + "\n  ".join(failures))
        sys.exit(1)
    print(f"OK: {len(bodies)} envelopes, {len(events)} event(s) and {len(sessions)} session update(s), "
          "all anonymous, with no device IDs and no paths.")


if __name__ == "__main__":
    main()
