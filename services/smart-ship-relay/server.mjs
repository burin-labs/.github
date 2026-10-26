import { createServer } from "node:http"
import { createRelay, normalizePem, parseRepos } from "./relay.mjs"

const MAX_BODY = 1024 * 1024

function required(name) {
  const value = process.env[name]
  if (!value) throw new Error(`${name} is required`)
  return value
}

export function startServer(relay, port) {
  const server = createServer(async (request, response) => {
    const chunks = []
    let size = 0
    try {
      for await (const chunk of request) {
        size += chunk.length
        if (size > MAX_BODY) {
          response.writeHead(413).end("too large")
          return
        }
        chunks.push(chunk)
      }
    } catch {
      // The client went away mid-body; there is nobody to answer.
      response.destroy()
      return
    }
    const path = (request.url ?? "").split("?")[0]
    let result
    try {
      result = await relay.handle({ method: request.method, path, headers: request.headers, body: Buffer.concat(chunks) })
    } catch (error) {
      // An unexpected throw must answer 500, not take the process down with it.
      console.log(JSON.stringify({ outcome: "error", error: String(error?.message) }))
      result = { status: 500, body: "internal error" }
    }
    response.writeHead(result.status, { "Content-Type": "text/plain" }).end(result.body)
  })
  return new Promise((resolve) => server.listen(port, () => resolve(server)))
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const relay = createRelay({
    secret: required("GITHUB_WEBHOOK_SECRET"),
    appId: required("GITHUB_APP_ID"),
    privateKey: normalizePem(required("GITHUB_APP_PRIVATE_KEY")),
    repos: parseRepos(required("RELAY_REPOS")),
    log: (line) => console.log(JSON.stringify(line)),
  })
  await startServer(relay, Number(process.env.PORT ?? 10000))
  console.log(JSON.stringify({ outcome: "listening" }))
}
