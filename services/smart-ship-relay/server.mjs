import { createServer } from "node:http"
import { createRelay, parseRepos } from "./relay.mjs"

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
    for await (const chunk of request) {
      size += chunk.length
      if (size > MAX_BODY) {
        response.writeHead(413).end("too large")
        return
      }
      chunks.push(chunk)
    }
    const path = (request.url ?? "").split("?")[0]
    const result = await relay.handle({ method: request.method, path, headers: request.headers, body: Buffer.concat(chunks) })
    response.writeHead(result.status, { "Content-Type": "text/plain" }).end(result.body)
  })
  return new Promise((resolve) => server.listen(port, () => resolve(server)))
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const relay = createRelay({
    secret: required("GITHUB_WEBHOOK_SECRET"),
    appId: required("GITHUB_APP_ID"),
    privateKey: required("GITHUB_APP_PRIVATE_KEY"),
    repos: parseRepos(required("RELAY_REPOS")),
    log: (line) => console.log(JSON.stringify(line)),
  })
  await startServer(relay, Number(process.env.PORT ?? 10000))
  console.log(JSON.stringify({ outcome: "listening" }))
}
