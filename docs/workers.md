# Connecting Miners

This stack is the **orchestrator** for your mining operation: every miner you own connects to a
**single endpoint**, and the stack routes their combined hashrate — handling pool selection,
payouts, and the P2Pool/XvB split centrally. Your miners stay dead simple; all the coordination
lives here.

The endpoint is the `xmrig-proxy` service on port **3333**.

> **You do not put a wallet address in your miner config.** Payouts are managed by the P2Pool
> service on the stack — miners only need to know *where the stack is*.

---

## Already have miners? Connect them

If you already run [XMRig](https://github.com/xmrig/xmrig) (or any RandomX miner), point it at the
stack and you're done. Use the machine running the stack as the host, on port `3333`:

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

That's the whole pool config. Start the miner and it appears in the dashboard's **Workers Alive**
table within a few seconds.

- **`user` is just a label** for the rig — use its hostname so you can tell workers apart on the
  dashboard. (No wallet address — see above.)
- **Point all your rigs at the same `YOUR_STACK_IP:3333`.** The stack aggregates them; there's
  nothing per-rig to configure beyond the label.
- **`YOUR_STACK_IP`** is the stack host's IP or a DNS-resolvable hostname. For a stable address
  on a home LAN, set a DHCP reservation (or a static IP) for the stack host.

### Miner version & compatibility

There's **no required miner version**. The stack's `xmrig-proxy` and P2Pool speak the standard
Stratum protocol and accept any miner that supports NiceHash (XMRig enables this automatically when
it connects through a proxy). Any reasonably recent **XMRig (5.0+, which introduced RandomX)** works
— the stack's component versions don't dictate a miner version. When in doubt, run the latest XMRig.

### Networking notes

- Miners connect over your local network (plain stratum). The Tor layer is for the stack's
  *upstream* connections to the Monero/Tari/P2Pool networks — **your rigs don't need Tor**.

### Firewall

- Port **3333** must be reachable from each miner to the stack machine. If the stack host has a
  firewall, allow inbound `3333` from your LAN.
- By default the stack publishes `3333` on **all** of the host's interfaces (`0.0.0.0`) so any rig
  on your LAN can connect with no extra setup. **On a host with a public IP, that port is reachable
  from the internet** — keep it firewalled to your LAN, and/or narrow the bind: set
  [`p2pool.stratum_bind`](configuration.md#configuration-reference) to a specific LAN IP (e.g.
  `192.168.1.10`) or to `127.0.0.1` to disable LAN access entirely. The stratum protocol is
  unauthenticated, so it should never be exposed to the public internet.

If a worker doesn't show up, see
[Operations › Troubleshooting](operations.md#troubleshooting).

---

## New to mining? Start with RigForge

If you don't have miners set up yet — or you want the best hashrate without hand-tuning — use
**[RigForge](https://github.com/p2pool-starter-stack/rigforge)**, the companion miner kit for this
stack.

RigForge turns a fresh machine into a fully tuned worker in one command: it builds XMRig from
source, applies CPU- and kernel-level tuning (HugePages, MSR, NUMA), and runs it as a managed
service. During setup it asks for your stack's hostname and wires up the `3333` connection for you.

```bash
git clone https://github.com/p2pool-starter-stack/rigforge.git
cd rigforge
chmod +x rigforge.sh
sudo ./rigforge.sh
```

See the **[RigForge README](https://github.com/p2pool-starter-stack/rigforge)** for the full guide,
including **[worker hardware requirements](https://github.com/p2pool-starter-stack/rigforge#-hardware-requirements)**,
kernel tuning, and verification.

---

## See also

- [Getting Started](getting-started.md) — first-run setup and what to expect while the node syncs.
- [The Dashboard](dashboard.md) — the Workers Alive table and per-worker stats.
- [Hardware Requirements](hardware.md) — sizing the **stack host** (miners are sized in RigForge).
