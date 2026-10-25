// Smart Ship thread relay: turns GitHub's `pull_request_review_thread` webhook
// into a `workflow_dispatch` look at one pull request. GitHub Actions has no
// trigger for that event, so a resolved or reopened conversation otherwise
// waits for the next sweep.
//
// Admission is the whole job. A delivery that cannot change a Smart Ship
// decision must start no billed Actions run, so everything below fails closed
// before the first call to the GitHub API.

import { createHmac, createSign, timingSafeEqual } from "node:crypto"

export const THREAD_ACTIONS = new Set(["resolved", "unresolved"])
const API = "https://api.github.com"
const MAX_SEEN = 4096

/** Parse `RELAY_REPOS`: a JSON object of `owner/name` to caller workflow file. */
export function parseRepos(text) {
  const parsed = JSON.parse(text ?? "")
  const entries = Object.entries(parsed)
  if (entries.length === 0) throw new Error("RELAY_REPOS names no repository")
  for (const [repo, workflow] of entries) {
    if (!/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(repo)) throw new Error(`bad repository: ${repo}`)
    if (typeof workflow !== "string" || !/^[A-Za-z0-9_.-]+\.ya?ml$/.test(workflow)) {
      throw new Error(`bad workflow file for ${repo}`)
    }
  }
  return new Map(entries)
}

export function signatureValid(secret, body, header) {
  if (typeof header !== "string" || !header.startsWith("sha256=")) return false
  const expected = createHmac("sha256", secret).update(body).digest()
  const given = Buffer.from(header.slice("sha256=".length), "hex")
  return given.length === expected.length && timingSafeEqual(given, expected)
}

const b64url = (value) => Buffer.from(value).toString("base64url")

export function appJwt(appId, privateKey, nowSeconds) {
  const head = b64url(JSON.stringify({ alg: "RS256", typ: "JWT" }))
  const claims = b64url(JSON.stringify({ iat: nowSeconds - 60, exp: nowSeconds + 540, iss: String(appId) }))
  const signature = createSign("RSA-SHA256").update(`${head}.${claims}`).sign(privateKey).toString("base64url")
  return `${head}.${claims}.${signature}`
}

/**
 * @param {{secret: string, appId: string, privateKey: string, repos: Map<string, string>,
 *   label?: string, fetch?: typeof fetch, now?: () => number, log?: (line: object) => void}} config
 */
export function createRelay(config) {
  const label = config.label ?? "ship"
  const call = config.fetch ?? fetch
  const now = config.now ?? (() => Date.now())
  const log = config.log ?? (() => {})
  const seen = new Set()

  const remember = (id) => {
    seen.add(id)
    if (seen.size > MAX_SEEN) seen.delete(seen.values().next().value)
  }

  async function github(path, token, init) {
    return call(`${API}${path}`, {
      ...init,
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "smart-ship-relay",
        "Content-Type": "application/json",
      },
    })
  }

  async function dispatch(payload, workflow) {
    const [owner, name] = payload.repository.full_name.split("/")
    const jwt = appJwt(config.appId, config.privateKey, Math.floor(now() / 1000))
    const minted = await github(`/app/installations/${payload.installation.id}/access_tokens`, jwt, {
      method: "POST",
      body: JSON.stringify({ repositories: [name], permissions: { actions: "write" } }),
    })
    if (minted.status !== 201) throw new Error(`installation token request answered ${minted.status}`)
    const { token } = await minted.json()
    const sent = await github(`/repos/${owner}/${name}/actions/workflows/${workflow}/dispatches`, token, {
      method: "POST",
      body: JSON.stringify({
        ref: payload.repository.default_branch,
        inputs: { pr: String(payload.pull_request.number) },
      }),
    })
    if (sent.status !== 204) throw new Error(`workflow dispatch answered ${sent.status}`)
  }

  /** @returns {Promise<{status: number, body: string}>} */
  async function handle({ method, path, headers, body }) {
    if (method === "GET" && path === "/healthz") return { status: 200, body: "ok" }
    if (method !== "POST" || path !== "/hooks/github") return { status: 404, body: "not found" }
    if (!signatureValid(config.secret, body, headers["x-hub-signature-256"])) {
      log({ outcome: "rejected", reason: "signature" })
      return { status: 401, body: "bad signature" }
    }
    const delivery = headers["x-github-delivery"] ?? ""
    const event = headers["x-github-event"]
    if (event === "ping") return { status: 200, body: "pong" }
    if (event !== "pull_request_review_thread") return skip(delivery, "event")
    let payload
    try {
      payload = JSON.parse(body.toString("utf8"))
    } catch {
      return { status: 400, body: "malformed payload" }
    }
    if (!THREAD_ACTIONS.has(payload?.action)) return skip(delivery, "action")
    const pull = payload.pull_request
    const repo = payload.repository?.full_name
    const workflow = config.repos.get(repo)
    if (!workflow) return skip(delivery, "repository")
    if (!Number.isInteger(pull?.number) || pull.number <= 0 || pull.state !== "open") return skip(delivery, "pull-request")
    if (!(pull.labels ?? []).some((entry) => entry?.name === label)) return skip(delivery, "unlabeled")
    if (!Number.isInteger(payload.installation?.id) || !payload.repository?.default_branch) {
      return skip(delivery, "installation")
    }
    if (delivery === "") return { status: 400, body: "missing delivery id" }
    if (seen.has(delivery)) return skip(delivery, "duplicate")
    try {
      await dispatch(payload, workflow)
    } catch (error) {
      // Not remembered, so GitHub's redelivery of a failed delivery can retry.
      log({ outcome: "failed", delivery, repo, pr: pull.number, error: String(error.message) })
      return { status: 502, body: "dispatch failed" }
    }
    remember(delivery)
    log({ outcome: "dispatched", delivery, repo, pr: pull.number, action: payload.action })
    return { status: 202, body: "dispatched" }
  }

  function skip(delivery, reason) {
    log({ outcome: "skipped", reason, delivery })
    return { status: 202, body: `skipped: ${reason}` }
  }

  return { handle }
}
