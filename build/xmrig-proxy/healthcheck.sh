#!/bin/bash
# xmrig-proxy control-API liveness (#904).
#
# A TCP connect to the HTTP API port proves the proxy is up and serving. The API — not the
# stratum listener — is the honest probe here: a failed stratum bind kills the process outright
# (the container restart is already visible), while the HTTP API can die quietly, and it is what
# the dashboard polls for worker stats. The port is read from the container env, never
# interpolated into the compose command (#90); a bare connect needs no token, so auth material
# stays out of the probe. /dev/tcp is a bash builtin (the image ships bash) so no extra tooling
# is needed; `timeout` guards against a wedged connect.
exec timeout 5 bash -c "</dev/tcp/127.0.0.1/${PROXY_API_PORT:?}" 2>/dev/null
