# Source archive manifest

All files fetched 2026-08-10 with `curl -sSL --fail --max-time 60` (2 tries per URL).
Hashes are `shasum -a 256` over the archived file.

## Archived

### github-schernykh-p2pool-repo-page.html
- Source: https://github.com/SChernykh/p2pool
- Fetched: 2026-08-10
- SHA-256: `9f51f11bb6860e379c2ead923d82cf51ff0d672502618488b340a6abc458b451`
- What: P2Pool README (GitHub repo page) — PPLNS window definition, sidechain block time, uncle support, payout proportionality.

### p2pool-README.md
- Source: https://raw.githubusercontent.com/SChernykh/p2pool/master/README.md
- Fetched: 2026-08-10
- SHA-256: `8173fc1ea0269e8d8003c741d4dfc9ac33f12f9f3781a90d2524fc4425cdd40d`
- What: P2Pool README, raw markdown — same content as the repo page without GitHub chrome; the study-cited canonical copy.

### p2pool-side_chain.cpp
- Source: https://raw.githubusercontent.com/SChernykh/p2pool/master/src/side_chain.cpp
- Fetched: 2026-08-10
- SHA-256: `ddbbd8575e2c40056eeaedb479ae5ddfbcd974ebe4436012b7c1bcaf7e86eced`
- What: P2Pool source — dynamic PPLNS window mechanism, uncle penalty, default sidechain parameters.

### monero-cryptonote_config.h
- Source: https://raw.githubusercontent.com/monero-project/monero/master/src/cryptonote_config.h
- Fetched: 2026-08-10
- SHA-256: `4c8a157b66e00a6bb20ebf377cf677632ec5611c5e57b9719f32e8116c84538f`
- What: Monero source — coinbase maturity (60-block unlock) and 120 s block target time (verifies the ~2 h unlock claim).

### xmrvsbeast-p2pool-dashboard.html
- Source: https://xmrvsbeast.com/p2pool/
- Fetched: 2026-08-10
- SHA-256: `0fa4b3f39f5fd3ed0a97ab94f78db16602f0921fa7ea0553aa77e02b42810de2`
- What: XvB raffle dashboard main page — the site's label for the bonus hashrate figure and links to rules/FAQ.

### xmrvsbeast-rules.html
- Source: https://xmrvsbeast.com/p2pool/rules.html
- Fetched: 2026-08-10
- SHA-256: `23d8668e0d36291b0c23a4e6bdd91f760907c55cbb20bd604cbc2e984b484996`
- What: Raffle rules page — round duration/extension, skip/fail rules, termination rule, tier thresholds, sidechain-application rule.

### xmrvsbeast-faq.html
- Source: https://xmrvsbeast.com/p2pool/faq.html
- Fetched: 2026-08-10
- SHA-256: `2163a4671f6db102a8f1d7da754dfda9b5f7dd8d3e8e89bcbcfe5f83341a35fc`
- What: Raffle FAQ — VIP/PPLNS share requirement wording and API endpoints.

### xmrvsbeast-reward_estimate_pub.txt
- Source: https://xmrvsbeast.com/p2pool/reward_estimate_pub.txt
- Fetched: 2026-08-10
- SHA-256: `acffb6167a4b8809ea2e7f0e0809909259c62fee7bd39fd39e5e65882390af6a`
- What: Published per-tier reward estimates, fetched verbatim — no methodology text or timestamp in the file.

### xmrvsbeast-winners_recent_full_pub.txt
- Source: https://xmrvsbeast.com/p2pool/winners_recent_full_pub.txt
- Fetched: 2026-08-10
- SHA-256: `0b390fbf9ffcce9ab1a47280b0d208fe5a2aae3776121ba8fd59f3241916007f`
- What: Live winners feed — tab-separated data rows with no header line naming the rate column.

### observer-api-docs-template.qtpl
- Source: https://git.gammaspectra.live/P2Pool/observer/raw/branch/master/cmd/web/views/api.qtpl
- Fetched: 2026-08-10
- SHA-256: `bfe8de8f73076d41f33d71657d26b121feb72b05bef22e3bfdcacaaae6ca280e`
- What: Source template of the p2pool.observer /api documentation page — all endpoints, parameters, and example payloads (pool_info, miner_info, side_blocks_in_window, payouts, found_blocks, shares, block_by_id).

### observer-side_block.go
- Source: https://git.gammaspectra.live/P2Pool/observer-cmd-utils/raw/branch/master/index/side_block.go
- Fetched: 2026-08-10
- SHA-256: `0b32e0492f81dd6f15deee77a9797f44c28c4744f8c0b1d12ab486ad2dbd09e0`
- What: SideBlock struct — authoritative field semantics for difficulty, inclusion, timestamp, miner id; uncle-penalty weighting.

### observer-README.md
- Source: https://git.gammaspectra.live/P2Pool/observer/raw/branch/master/README.md
- Fetched: 2026-08-10
- SHA-256: `d4d2ccafe570aaea7f636627b553108273d6cc826078eacb2a07c79edf48f11f`
- What: Observer project README — maintainer-run instances (main/mini/nano/old), self-hosting instructions.

### p2pool-observer-go-README.md
- Source: https://git.gammaspectra.live/P2Pool/p2pool-observer/raw/branch/master/README.md
- Fetched: 2026-08-10
- SHA-256: `4f2c94b43cb2d1d5cd0989b92202bf3d9019e1c2384d16d48689c1fbfca04c82`
- What: Go consensus repo README (points to P2Pool/observer as the site/API repo).

## Unreachable

### https://p2pool.observer/faq — UNREACHABLE
- 2 tries on 2026-08-10, HTTP 418 both times (Cloudflare-style bot check; no content retrieved).
- Mechanics verified from the p2pool README and source instead.

### https://p2pool.observer/api — UNREACHABLE
- 2 tries on 2026-08-10, HTTP 418 both times (interactive challenge blocks automated fetch).
- The page's content is archived via its source template, `observer-api-docs-template.qtpl` above.

### https://mini.p2pool.observer/api — UNREACHABLE
- 2 tries on 2026-08-10, HTTP 418 both times (same block as the main instance).
- Same documentation covered by `observer-api-docs-template.qtpl` above.

## Archived 2026-08-11 (operator browser fetch — bot-challenge pages)

### observer-api-docs-live.html
- Source: https://p2pool.observer/api (and mini.p2pool.observer/api — identical documentation)
- Fetched: 2026-08-11 (browser, saved by operator)
- SHA-256: `9e788a888ecf5aa4faa9a017b2cafa69547db24602f167716c2eecd059faab52`
- What: Live observer API documentation page, browser-fetched by the operator through the site's bot challenge; validates the source-template archive and documents /api/side_blocks_in_window/<id|address> used by the planned generalization study.

### p2pool-io-api-index.html
- Source: https://p2pool.io/api/
- Fetched: 2026-08-11 (browser, saved by operator)
- SHA-256: `019573e803939c34f1b39e9d1fd1fc64867a800da8ccfdf616fa033e4274c4fc`
- What: P2Pool pool-API directory index (network/, pool/, stats_mod, tail.json).

### p2pool-io-main-and-faq.html
- Source: https://p2pool.io/#faq
- Fetched: 2026-08-11 (browser, saved by operator)
- SHA-256: `46bd5ab09471fac558e91d183e89bb48fd69fa41eecbfa533f0a9aee5eb65001`
- What: p2pool.io main page incl. FAQ and pool stats logic: PPLNS window duration = pplnsWeight/hashRate, min payout = 0.6 x sidechainDifficulty/pplnsWeight, and the mini/nano observer instance links.

### Note on previously UNREACHABLE entries
- p2pool.observer/api and mini.p2pool.observer/api are now covered by `observer-api-docs-live.html` (identical docs for both instances).
- p2pool.observer/faq itself remains unarchived; `p2pool-io-main-and-faq.html` archives the p2pool.io FAQ (a different site) as an additional mechanics source.

### xmrvsbeast-reward_calc.sh
- Source: operator-published calculator script (user-supplied copy, obtained 2026-08-02)
- Archived: 2026-08-12
- SHA-256: `9e6155f736824f20a0d392f4193f2df77f1f611e95ce2e31a8285010dd571174`
- What: XvB's own reward_calc.sh — the generator of reward_estimate_pub.txt; averages the winners feed's rate column as "bonus hr" and prices it at full block reward.
