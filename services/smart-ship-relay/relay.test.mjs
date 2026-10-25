import assert from "node:assert/strict"
import { createHmac, createPublicKey, createVerify, generateKeyPairSync } from "node:crypto"
import { test } from "node:test"
import { createRelay, normalizePem, parseRepos, signatureValid } from "./relay.mjs"
import { startServer } from "./server.mjs"

const SECRET = "test-secret"
const { privateKey, publicKey } = generateKeyPairSync("rsa", {
  modulusLength: 2048,
  privateKeyEncoding: { type: "pkcs8", format: "pem" },
  publicKeyEncoding: { type: "spki", format: "pem" },
})

function harness(overrides = {}) {
  const calls = []
  const answers = overrides.answers ?? { token: 201, dispatch: 204 }
  const fetch = async (url, init) => {
    calls.push({ url, init })
    if (url.endsWith("/access_tokens")) {
      return new Response(JSON.stringify({ token: "installation-token" }), { status: answers.token })
    }
    return new Response(null, { status: answers.dispatch })
  }
  const logs = []
  const relay = createRelay({
    secret: SECRET,
    appId: "123",
    privateKey,
    repos: parseRepos('{"burin-labs/harn":"smart-ship.yml","burin-labs/.github":"ship.yml"}'),
    fetch,
    now: () => 1_800_000_000_000,
    log: (line) => logs.push(line),
  })
  return { relay, calls, logs }
}

const payload = (patch = {}) => ({
  action: "resolved",
  pull_request: { number: 42, state: "open", labels: [{ name: "ship" }] },
  repository: { full_name: "burin-labs/harn", default_branch: "main" },
  installation: { id: 77 },
  ...patch,
})

function delivery(body, { event = "pull_request_review_thread", id = "d-1", secret = SECRET, signature } = {}) {
  const raw = Buffer.from(JSON.stringify(body))
  const header = signature ?? "sha256=" + createHmac("sha256", secret).update(raw).digest("hex")
  return {
    method: "POST",
    path: "/hooks/github",
    headers: { "x-hub-signature-256": header, "x-github-event": event, "x-github-delivery": id },
    body: raw,
  }
}

test("a resolved thread on a labeled PR dispatches one look at that PR", async () => {
  const { relay, calls } = harness()
  const result = await relay.handle(delivery(payload()))
  assert.equal(result.status, 202)
  assert.equal(result.body, "dispatched")
  assert.equal(calls.length, 2)
  assert.equal(calls[0].url, "https://api.github.com/app/installations/77/access_tokens")
  assert.deepEqual(JSON.parse(calls[0].init.body), { repositories: ["harn"], permissions: { actions: "write" } })
  assert.equal(calls[1].url, "https://api.github.com/repos/burin-labs/harn/actions/workflows/smart-ship.yml/dispatches")
  assert.equal(calls[1].init.headers.Authorization, "Bearer installation-token")
  assert.deepEqual(JSON.parse(calls[1].init.body), { ref: "main", inputs: { pr: "42" } })
})

test("a reopened thread dispatches too, and each repository uses its own caller file", async () => {
  const { relay, calls } = harness()
  const body = payload({ action: "unresolved", repository: { full_name: "burin-labs/.github", default_branch: "main" } })
  assert.equal((await relay.handle(delivery(body))).body, "dispatched")
  assert.match(calls[1].url, /workflows\/ship\.yml\/dispatches$/)
})

test("the App JWT is a valid RS256 token for the App", async () => {
  const { relay, calls } = harness()
  await relay.handle(delivery(payload()))
  const [head, claims, signature] = calls[0].init.headers.Authorization.slice("Bearer ".length).split(".")
  const verify = createVerify("RSA-SHA256").update(`${head}.${claims}`)
  assert.equal(verify.verify(createPublicKey(publicKey), Buffer.from(signature, "base64url")), true)
  const decoded = JSON.parse(Buffer.from(claims, "base64url"))
  assert.deepEqual(decoded, { iat: 1_799_999_940, exp: 1_800_000_540, iss: "123" })
})

// Negative controls: each of these must start no Actions run, so none may reach the API.
const silent = [
  ["an unlabeled PR", delivery(payload({ pull_request: { number: 42, state: "open", labels: [{ name: "hold" }] } })), "unlabeled"],
  ["a PR with no labels field", delivery(payload({ pull_request: { number: 42, state: "open" } })), "unlabeled"],
  ["a closed PR", delivery(payload({ pull_request: { number: 42, state: "closed", labels: [{ name: "ship" }] } })), "pull-request"],
  ["a repository outside the allowlist", delivery(payload({ repository: { full_name: "other/repo", default_branch: "main" } })), "repository"],
  ["an unexpected action", delivery(payload({ action: "edited" })), "action"],
  ["another event", delivery(payload(), { event: "pull_request_review" }), "event"],
  ["a missing installation", delivery(payload({ installation: undefined })), "installation"],
]
for (const [name, request, reason] of silent) {
  test(`${name} starts no dispatch`, async () => {
    const { relay, calls } = harness()
    const result = await relay.handle(request)
    assert.equal(result.status, 202)
    assert.equal(result.body, `skipped: ${reason}`)
    assert.equal(calls.length, 0)
  })
}

test("signature rejects reach no API call and no payload parsing", async () => {
  const { relay, calls } = harness()
  const good = delivery(payload())
  const cases = [
    { ...good, headers: { ...good.headers, "x-hub-signature-256": undefined } },
    delivery(payload(), { secret: "wrong" }),
    delivery(payload(), { signature: "sha256=" }),
    delivery(payload(), { signature: "sha256=zz" }),
    delivery(payload(), { signature: "sha1=" + "0".repeat(40) }),
    { ...good, body: Buffer.from(good.body.toString() + " ") },
  ]
  for (const request of cases) assert.equal((await relay.handle(request)).status, 401)
  assert.equal(calls.length, 0)
})

test("a redelivered delivery id dispatches once", async () => {
  const { relay, calls } = harness()
  assert.equal((await relay.handle(delivery(payload(), { id: "same" }))).body, "dispatched")
  assert.equal((await relay.handle(delivery(payload(), { id: "same" }))).body, "skipped: duplicate")
  assert.equal(calls.length, 2)
  assert.equal((await relay.handle(delivery(payload(), { id: "other" }))).body, "dispatched")
})

test("a failed dispatch answers 502 and lets GitHub's redelivery retry", async () => {
  for (const answers of [{ token: 401, dispatch: 204 }, { token: 201, dispatch: 422 }]) {
    const failing = harness({ answers })
    assert.equal((await failing.relay.handle(delivery(payload(), { id: "retry" }))).status, 502)
    assert.equal(failing.logs.at(-1).outcome, "failed")
  }
  const { relay } = harness()
  assert.equal((await relay.handle(delivery(payload(), { id: "retry" }))).status, 202)
})

test("ping, health and unknown routes", async () => {
  const { relay, calls } = harness()
  assert.equal((await relay.handle(delivery({}, { event: "ping" }))).body, "pong")
  assert.equal((await relay.handle({ method: "GET", path: "/healthz", headers: {}, body: Buffer.alloc(0) })).status, 200)
  assert.equal((await relay.handle({ method: "GET", path: "/hooks/github", headers: {}, body: Buffer.alloc(0) })).status, 404)
  assert.equal(calls.length, 0)
})

test("logs never carry the secret, the key or the tokens", async () => {
  const { relay, logs } = harness()
  await relay.handle(delivery(payload()))
  const text = JSON.stringify(logs)
  for (const secret of [SECRET, "installation-token", "PRIVATE KEY"]) assert(!text.includes(secret))
})

test("configuration refuses an empty or malformed repository map", () => {
  assert.throws(() => parseRepos("{}"))
  assert.throws(() => parseRepos('{"nope":"smart-ship.yml"}'))
  assert.throws(() => parseRepos('{"a/b":"../x"}'))
  assert.equal(signatureValid("s", Buffer.from("x"), undefined), false)
})

test("the HTTP server reaches the relay and bounds the body", async () => {
  const { relay } = harness()
  const server = await startServer(relay, 0)
  const base = `http://127.0.0.1:${server.address().port}`
  try {
    assert.equal((await fetch(`${base}/healthz`)).status, 200)
    const unsigned = await fetch(`${base}/hooks/github`, { method: "POST", body: "{}" })
    assert.equal(unsigned.status, 401)
    const huge = await fetch(`${base}/hooks/github`, { method: "POST", body: Buffer.alloc(1024 * 1024 + 1) }).catch(() => ({ status: 413 }))
    assert.equal(huge.status, 413)
  } finally {
    server.close()
  }
})

test("a one-line PEM with escaped newlines is restored, and a real PEM is left alone", () => {
  const escaped = privateKey.trim().replace(/\n/g, "\\n")
  assert.ok(!escaped.includes("\n"))
  assert.equal(normalizePem(escaped).trim(), privateKey.trim())
  assert.equal(normalizePem(privateKey), privateKey)
})

test("an unexpected throw answers 500 and the server keeps serving", async () => {
  const server = await startServer({ handle: async () => { throw new Error("boom") } }, 0)
  try {
    const url = `http://127.0.0.1:${server.address().port}/hooks/github`
    const first = await fetch(url, { method: "POST", body: "{}" })
    assert.equal(first.status, 500)
    const second = await fetch(url, { method: "POST", body: "{}" })
    assert.equal(second.status, 500)
  } finally {
    server.close()
  }
})

test("a redelivery that arrives while the first request is still dispatching dispatches once", async () => {
  let release
  const gate = new Promise((resolve) => { release = resolve })
  const calls = []
  const relay = createRelay({
    secret: SECRET,
    appId: "123",
    privateKey,
    repos: parseRepos('{"burin-labs/harn":"smart-ship.yml"}'),
    fetch: async (url, init) => {
      calls.push(url)
      await gate
      if (url.endsWith("/access_tokens")) return new Response(JSON.stringify({ token: "t" }), { status: 201 })
      return new Response(null, { status: 204 })
    },
    now: () => 1_800_000_000_000,
  })
  const first = relay.handle(delivery(payload(), { id: "slow" }))
  const second = await relay.handle(delivery(payload(), { id: "slow" }))
  assert.equal(second.body, "skipped: duplicate")
  release()
  assert.equal((await first).body, "dispatched")
  assert.equal(calls.filter((url) => url.endsWith("/dispatches")).length, 1)
})

test("a failed dispatch releases its reservation so the retry can dispatch", async () => {
  let dispatchStatus = 422
  const relay = createRelay({
    secret: SECRET,
    appId: "123",
    privateKey,
    repos: parseRepos('{"burin-labs/harn":"smart-ship.yml"}'),
    fetch: async (url) => {
      if (url.endsWith("/access_tokens")) return new Response(JSON.stringify({ token: "t" }), { status: 201 })
      return new Response(null, { status: dispatchStatus })
    },
    now: () => 1_800_000_000_000,
  })
  assert.equal((await relay.handle(delivery(payload(), { id: "again" }))).status, 502)
  dispatchStatus = 204
  assert.equal((await relay.handle(delivery(payload(), { id: "again" }))).body, "dispatched")
})

test("a client that disconnects mid-body does not take the server down", async () => {
  const server = await startServer(createRelay({
    secret: SECRET, appId: "1", privateKey, repos: parseRepos('{"burin-labs/harn":"smart-ship.yml"}'),
  }), 0)
  try {
    const { port } = server.address()
    const net = await import("node:net")
    await new Promise((resolve) => {
      const socket = net.connect(port, "127.0.0.1", () => {
        socket.write("POST /hooks/github HTTP/1.1\r\nHost: x\r\nContent-Length: 100\r\n\r\npartial")
        setTimeout(() => { socket.destroy(); resolve() }, 20)
      })
    })
    await new Promise((resolve) => setTimeout(resolve, 50))
    const alive = await fetch(`http://127.0.0.1:${port}/healthz`)
    assert.equal(alive.status, 200)
  } finally {
    server.close()
  }
})
