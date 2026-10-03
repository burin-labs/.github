import test from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createServer } from "node:http";
import { readBaseline, publishBaseline } from "./read-baseline.mjs";

const sha = "a".repeat(40);
const treeSha = "b".repeat(40);
const request = { repository: "burin-labs/example", policy: ".github/ci-latency.json", sha, token: "fixture-token" };
const policy = { repository: request.repository, schema_version: 1 };
const response = (status, value = {}, headers) => new Response(JSON.stringify(value), { status, headers });

function transport(responses) {
  const calls = [];
  const delays = [];
  let elapsed = 0;
  return { calls, delays, options: {
    fetch: async (url, options) => {
      assert.equal(options.headers.Authorization, "Bearer fixture-token");
      assert.equal(options.redirect, "error");
      assert.ok(options.signal instanceof AbortSignal);
      calls.push(url);
      assert.ok(responses.length > 0, "unmeasured extra request");
      const next = responses.shift();
      if (next instanceof Error) throw next;
      return next;
    },
    sleep: async ms => { delays.push(ms); elapsed += ms; },
    now: () => elapsed,
  } };
}

test("actual reader recovers structured 503 then publishes complete 200 atomically", async () => {
  const source = transport([response(503), response(200, policy)]);
  const result = await readBaseline(request, source.options);
  assert.equal(result.state, "found");
  assert.equal(result.pendingCount, 0);
  assert.equal(result.attempts, 2);
  assert.equal(source.calls.length, 2);
  assert.deepEqual(source.delays, [1000]);
  assert.deepEqual(JSON.parse(result.bytes), policy);
  const root = await mkdtemp(join(tmpdir(), "immutable-baseline-test-"));
  try {
    const destination = join(root, "baseline.json");
    await writeFile(destination, "previous qualified baseline");
    await publishBaseline(result, destination);
    assert.deepEqual(JSON.parse(await readFile(destination, "utf8")), policy);
    assert.equal((await stat(destination)).mode & 0o777, 0o600);
    await assert.rejects(publishBaseline({ state: "absent" }, destination));
    assert.deepEqual(JSON.parse(await readFile(destination, "utf8")), policy);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test("exhausted 503 refuses after exactly three attempts", async () => {
  const source = transport([response(503), response(503), response(503)]);
  await assert.rejects(readBaseline(request, source.options), /HTTP 503 exhausted 3 attempts; pending=1/);
  assert.equal(source.calls.length, 3);
  assert.deepEqual(source.delays, [1000, 2000]);
});

test("permanent 403 refuses once with no retry or published output", async () => {
  const source = transport([response(403)]);
  await assert.rejects(readBaseline(request, source.options), /HTTP 403; pending=1/);
  assert.equal(source.calls.length, 1);
  assert.deepEqual(source.delays, []);
});

test("interrupted and malformed 200 bodies refuse without retry", async () => {
  const interrupted = new Response(new ReadableStream({
    start(controller) { controller.enqueue(new TextEncoder().encode('{"repository":')); controller.error(new Error("partial")); },
  }));
  for (const reply of [interrupted, new Response('{"repository":'), response(200, null),
    response(200, policy, { "content-length": "999" }), { status: 200, headers: new Headers() }]) {
    const source = transport([reply]);
    await assert.rejects(readBaseline(request, source.options), /body|JSON/);
    assert.equal(source.calls.length, 1);
    assert.deepEqual(source.delays, []);
  }
});

test("transport and status absence refuse rather than count as initial policy", async () => {
  for (const reply of [new Error("unreadable transport"), {}, { status: 0 }]) {
    const source = transport([reply]);
    await assert.rejects(readBaseline(request, source.options), /unmeasured/);
    assert.equal(source.calls.length, 1);
  }
  await assert.rejects(readBaseline(request, { fetch: null }), /existing Node runtime/);
});

test("404 counts as absence only after authenticated commit and complete non-null tree", async () => {
  const source = transport([response(404), response(200, { sha, tree: { sha: treeSha } }),
    response(200, { sha: treeSha, truncated: false, tree: [{ path: "README.md", type: "blob" }] })]);
  const result = await readBaseline(request, source.options);
  assert.equal(result.state, "absent");
  assert.equal(result.measuredEntries, 1);
  assert.equal(result.attempts, 3);
  assert.equal(source.calls.length, 3);
  assert.ok(source.calls[1].endsWith(`git/commits/${sha}`));
  assert.ok(source.calls[2].endsWith(`git/trees/${treeSha}?recursive=1`));
});

test("404 with partial, empty, duplicate or contradictory tree refuses", async () => {
  for (const tree of [
    { sha: treeSha, truncated: true, tree: [{ path: "README.md", type: "blob" }] },
    { sha: treeSha, truncated: false, tree: [] },
    { sha: treeSha, truncated: false },
    { sha: treeSha, truncated: false, tree: [{ path: request.policy, type: "blob" }] },
    { sha: treeSha, truncated: false, tree: [{ path: "README.md", type: "blob" }, { path: "README.md", type: "blob" }] },
  ]) {
    const source = transport([response(404), response(200, { sha, tree: { sha: treeSha } }), response(200, tree)]);
    await assert.rejects(readBaseline(request, source.options), /partial|unmeasured|retrieval failed/);
    assert.equal(source.calls.length, 3);
  }
  const denied = transport([response(404), response(403)]);
  await assert.rejects(readBaseline(request, denied.options), /census HTTP 403/);
  assert.equal(denied.calls.length, 2);
});

test("Retry-After and immutable identity cannot escape the bound", async () => {
  const source = transport([response(503, {}, { "retry-after": "3600" })]);
  await assert.rejects(readBaseline(request, source.options), /cannot fit its deadline/);
  assert.equal(source.calls.length, 1);
  assert.deepEqual(source.delays, []);
  for (const invalid of [{ ...request, sha: "main" }, { ...request, policy: "../policy.json" },
    { ...request, repository: "../example" }, { ...request, token: "line\ninjection" }]) {
    const unused = transport([]);
    await assert.rejects(readBaseline(invalid, unused.options));
    assert.equal(unused.calls.length, 0);
  }
});

test("native fetch aborts a stalled body within the remaining shared deadline", async () => {
  const server = createServer((_request, reply) => {
    reply.writeHead(200, { "content-type": "application/json" });
    reply.write('{"repository":');
  });
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  const started = performance.now();
  let clockReads = 0;
  try {
    await assert.rejects(readBaseline(request, {
      now: () => clockReads++ === 0 ? 0 : 59_750,
      fetch: (_url, options) => fetch(`http://127.0.0.1:${server.address().port}`, options),
    }), /incomplete|unmeasured/);
    assert.ok(performance.now() - started < 2000, "native body abort exceeded its remaining deadline");
  } finally {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  }
});

test("commit and tree retries consume the same deadline as the initial contents read", async () => {
  let elapsed = 0;
  let attempts = 0;
  await assert.rejects(readBaseline(request, {
    now: () => elapsed,
    sleep: async ms => { elapsed += ms + 500; },
    fetch: async () => {
      attempts += 1;
      elapsed += 19_500;
      if (attempts === 1) return response(404);
      if (attempts === 2) return response(200, { sha, tree: { sha: treeSha } });
      return response(503);
    },
  }), /deadline exhausted/);
  assert.equal(attempts, 3, "a new tree endpoint must not get a fresh60second budget");
  assert.equal(elapsed, 60_000);
});
