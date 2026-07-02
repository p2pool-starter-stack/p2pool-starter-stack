"""Fake Healthchecks.io ping receiver for the mini-stack e2e (#79).

Records the request path of every ping to a log file so the runner can assert the REAL
dashboard loop actually fired a liveness heartbeat end to end, not against a mocked
``requests.get``. Deliberately tiny: stdlib only, always 200 OK (like hc-ping.com).
"""

import argparse
from http.server import BaseHTTPRequestHandler, HTTPServer


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=9000)
    ap.add_argument("--log", default="/tmp/pings.log")  # noqa: S108 — throwaway itest container
    args = ap.parse_args()

    class Handler(BaseHTTPRequestHandler):
        def _record(self):
            # Append the path (e.g. "/ph" for a heartbeat, "/ph/fail" for a node-down signal)
            # so the runner can grep it. Flush so the assertion sees it without a delay.
            with open(args.log, "a") as f:
                f.write(self.path + "\n")
                f.flush()
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"OK")

        do_GET = _record
        do_POST = _record
        do_HEAD = _record

        def log_message(self, *_):
            pass  # keep the container logs quiet

    HTTPServer(("0.0.0.0", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
