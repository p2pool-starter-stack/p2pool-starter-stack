#!/bin/bash
# p2pool stratum liveness check (#90).
#
# A successful TCP connect to the stratum port proves p2pool is up and accepting miners — the
# failure mode workers actually feel. Uses bash's /dev/tcp builtin so the image needs no extra
# tooling (curl/nc/ps are not installed). `timeout` guards against a wedged connect.
exec timeout 5 bash -c '</dev/tcp/127.0.0.1/3333' 2>/dev/null
