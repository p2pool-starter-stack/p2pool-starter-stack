#!/bin/bash
# Dashboard HTTP liveness (#904).
#
# HEAD /api/state against the app's fixed loopback bind (main.py: 127.0.0.1:8000). aiohttp
# serves HEAD on every GET route, so a 200 proves the web server is listening AND build_state
# assembles — the exact "container Up while Caddy serves 502s" state the v1.8.1 one-click
# incident exposed (#622). The slim image ships no curl/wget; python3 (the app's own venv,
# already on PATH) probes with stdlib urllib, which raises — exiting non-zero — on any
# connect failure or non-2xx status.
exec python3 -c 'import urllib.request as u; u.urlopen(u.Request("http://127.0.0.1:8000/api/state", method="HEAD"), timeout=5)'
