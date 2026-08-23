// Unit tests for the click-to-adopt panel logic (#893):
// mining_dashboard/web/static/workeradoptlogic.mjs — field validation (the UX-layer mirror of
// pithead's host/port/token shape guard) and the workers.list[] append the form submits.
//
// Run with Node's built-in test runner (CI runs exactly this):
//     node --test dashboard/tests/frontend/
//
// Mutation-kill notes: each "refused" test would pass a value straight through (empty string, no
// error) if its guard were removed or its regex/range check inverted — the paired "accepted" tests
// on well-formed input catch the opposite direction (a guard so tight it refuses everything).
import assert from "node:assert/strict";
import { test } from "node:test";

import {
  buildAdoptedConfig,
  DEFAULT_CONTROL_PORT,
  hostIsInternal,
  validateAdoptFields,
} from "../../mining_dashboard/web/static/workeradoptlogic.mjs";

// --- validateAdoptFields --------------------------------------------------------------------

test("validateAdoptFields: a well-formed host/port/token is accepted", () => {
  assert.equal(validateAdoptFields("10.0.0.9", "8082", "tok-123"), "");
  assert.equal(validateAdoptFields("rig1.lan", DEFAULT_CONTROL_PORT, "tok-123"), "");
});

test("validateAdoptFields: an empty host is refused", () => {
  assert.notEqual(validateAdoptFields("", "8082", "tok"), "");
  assert.notEqual(validateAdoptFields("   ", "8082", "tok"), "");
});

test("validateAdoptFields: a host carrying a port is refused (#122 charset guard)", () => {
  assert.notEqual(validateAdoptFields("10.0.0.9:8082", "8082", "tok"), "");
});

test("validateAdoptFields: a host carrying a path is refused", () => {
  assert.notEqual(validateAdoptFields("10.0.0.9/../etc", "8082", "tok"), "");
});

test("validateAdoptFields: a host carrying userinfo is refused", () => {
  assert.notEqual(validateAdoptFields("user@10.0.0.9", "8082", "tok"), "");
});

test("validateAdoptFields: a scheme-prefixed host is refused", () => {
  assert.notEqual(validateAdoptFields("http://10.0.0.9", "8082", "tok"), "");
});

test("validateAdoptFields: control_port out of range is refused", () => {
  assert.notEqual(validateAdoptFields("10.0.0.9", "0", "tok"), "");
  assert.notEqual(validateAdoptFields("10.0.0.9", "65536", "tok"), "");
});

test("validateAdoptFields: a non-numeric control_port is refused", () => {
  assert.notEqual(validateAdoptFields("10.0.0.9", "abc", "tok"), "");
});

test("validateAdoptFields: a blank token is refused (bearer-mandatory)", () => {
  assert.notEqual(validateAdoptFields("10.0.0.9", "8082", ""), "");
  assert.notEqual(validateAdoptFields("10.0.0.9", "8082", "   "), "");
});

test("validateAdoptFields: a token with a space is refused", () => {
  assert.notEqual(validateAdoptFields("10.0.0.9", "8082", "has space"), "");
});

// --- hostIsInternal (the #122 SSRF floor on a NEW entry) --------------------------------------

test("hostIsInternal: loopback, localhost, link-local, multicast and reserved are internal", () => {
  for (const h of ["127.0.0.1", "localhost", "LOCALHOST", "sub.localhost", "0.0.0.0", "169.254.169.254", "224.0.0.1", "240.0.0.1"]) {
    assert.equal(hostIsInternal(h), true, h);
  }
});

test("hostIsInternal: ordinary LAN/public addresses and hostnames are not internal", () => {
  for (const h of ["192.168.1.50", "10.0.0.9", "8.8.8.8", "rig1.example.com"]) {
    assert.equal(hostIsInternal(h), false, h);
  }
});

test("hostIsInternal: the stack's own docker-bridge subnet is internal, default and custom", () => {
  assert.equal(hostIsInternal("172.28.0.5"), true); // default subnet, no override passed
  assert.equal(hostIsInternal("172.28.0.5", "172.30.0.0/24"), false); // off the CUSTOM subnet
  assert.equal(hostIsInternal("172.30.0.5", "172.30.0.0/24"), true);
});

test("hostIsInternal: alternate IP encodings are refused, not waved through as hostnames", () => {
  // The actual bypass a security review found: each of these fails the naive 4-octet regex, and
  // the original bug then treated "not a recognized dotted-decimal" as "must be a hostname,
  // therefore safe" — exactly the class this stack's own dial (curl) still resolves to a real,
  // dangerous address (all verified against a real curl build during development).
  for (const h of [
    "2130706433", // bare decimal == 127.0.0.1
    "2852039166", // bare decimal == 169.254.169.254 (cloud metadata)
    "0177.0.0.1", // octal-leading-zero octet == 127.0.0.1
    "0x7f000001", // hex == 127.0.0.1
    "0x7f.0x0.0x0.0x1", // per-octet hex == 127.0.0.1
    "127.1", // short/collapsed form == 127.0.0.1
    "010.0.0.1", // octal-leading-zero first octet == 8.0.0.1; refused outright either way
    "000.1.2.3",
  ]) {
    assert.equal(hostIsInternal(h), true, h);
  }
});

test("hostIsInternal: the 0.0.0.0/8 'this network' block is refused beyond the bare address", () => {
  assert.equal(hostIsInternal("0.1.2.3"), true);
});

test("hostIsInternal: a hex literal is refused even though it contains letters", () => {
  assert.equal(hostIsInternal("0xc0.0xa8.0x01.0x32"), true);
});

test("hostIsInternal: ordinary hostnames with digits still pass", () => {
  for (const h of ["rig-1.lan", "a.b.c.d", "rig01.example.com"]) {
    assert.equal(hostIsInternal(h), false, h);
  }
});

// --- buildAdoptedConfig ----------------------------------------------------------------------

test("buildAdoptedConfig: appends the new descriptor to an empty workers.list[]", () => {
  const cfg = buildAdoptedConfig({ p2pool: { pool: "mini" } }, "rig1", "10.0.0.9", "8082", "tok");
  assert.deepEqual(cfg.workers.list, [
    { name: "rig1", host: "10.0.0.9", control_port: 8082, token: "tok" },
  ]);
  assert.equal(cfg.p2pool.pool, "mini"); // every other key rides through untouched
});

test("buildAdoptedConfig: control_port is coerced to a number", () => {
  const cfg = buildAdoptedConfig({}, "rig1", "10.0.0.9", "8082", "tok");
  assert.equal(cfg.workers.list[0].control_port, 8082);
  assert.equal(typeof cfg.workers.list[0].control_port, "number");
});

test("buildAdoptedConfig: an existing entry reappears byte-for-byte, unchanged", () => {
  // The whole point of the add-only shape: the host's own gate refuses anything that touches an
  // already-live descriptor, so this MUST preserve rig1 exactly while appending rig2.
  const live = {
    workers: { list: [{ name: "rig1", host: "10.0.0.9", control_port: 8082, token: "tok1" }] },
  };
  const cfg = buildAdoptedConfig(live, "rig2", "10.0.0.10", "8082", "tok2");
  assert.deepEqual(cfg.workers.list[0], live.workers.list[0]);
  assert.equal(cfg.workers.list.length, 2);
  assert.equal(cfg.workers.list[1].name, "rig2");
});

test("buildAdoptedConfig: never mutates the live config object it was handed", () => {
  const live = { workers: { list: [{ name: "rig1", host: "a", token: "t" }] } };
  const before = JSON.stringify(live);
  buildAdoptedConfig(live, "rig2", "10.0.0.10", "8082", "tok2");
  assert.equal(JSON.stringify(live), before);
});

test("buildAdoptedConfig: trims stray whitespace off host and token", () => {
  const cfg = buildAdoptedConfig({}, "rig1", " 10.0.0.9 ", "8082", " tok \n");
  assert.equal(cfg.workers.list[0].host, "10.0.0.9");
  assert.equal(cfg.workers.list[0].token, "tok");
});
