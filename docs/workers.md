# Adding Workers

Your mining hardware connects to the stack through a **single endpoint**: the `xmrig-proxy`
service on port **3333**. The stack handles pool selection, payouts, and the P2Pool/XvB split
centrally, so each rig's configuration stays dead simple.

> **You do not put your wallet address in your worker config.** Payouts are managed by the
> P2Pool service on the stack. Workers only need to know *where the stack is*.

> 🧮 **What hardware should a worker have?** Workers do the actual RandomX hashing, so their specs
> matter most for hashrate. See the worker kit's
> [Hardware Requirements](../worker/Readme.md#-hardware-requirements).

## Connect any XMRig worker

Point your worker at the IP (or hostname) of the machine running the stack, on port `3333`. The
`user` field is just a label for the rig — use its hostname so you can tell workers apart on the
dashboard.

Minimal `config.json` for a manually configured [XMRig](https://github.com/xmrig/xmrig) worker:

```json
{
    "pools": [
        {
            "url": "YOUR_STACK_IP:3333",
            "user": "my-rig-01"
        }
    ]
}
```

That's it — start XMRig and the rig appears in the dashboard's **Workers Alive** table within a
few seconds.

### Networking notes

- Port **3333** must be reachable from each worker to the stack machine. If the stack host has a
  firewall, allow inbound `3333` from your LAN.
- Workers connect over your local network (plain stratum). The Tor layer is for the stack's
  *upstream* connections to the Monero/Tari/P2Pool networks — your rigs don't need Tor.

---

## The worker provisioning kit

For a fully automated, performance-tuned worker, use the self-contained kit in the
[`worker/`](../worker/) directory. It builds XMRig from source, applies kernel- and CPU-level tuning
for maximum hashrate, and runs it as a managed `systemd` service — a fully provisioned worker in one
command:

```bash
git clone https://github.com/p2pool-starter-stack/p2pool-starter-stack.git
cd p2pool-starter-stack/worker
chmod +x p2pool-starter-worker.sh
sudo ./p2pool-starter-worker.sh
```

The kit is documented end-to-end in its own **[README](../worker/Readme.md)** — capabilities,
hardware requirements, deployment, kernel tuning, maintenance, and verification.
