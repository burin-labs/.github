# Verified release assets

The shared release asset downloader obtains checksum-verified bytes. The calling
tool continues to own its cache, extraction, executable verification, and install.
It requires Harn 0.10.192.

## Use from a workflow

Pin `burin-labs/.github/.github/actions/download-release-asset` to a reviewed
commit. Supply `url`, `sha256`, `output`, and `github-token`. Preserve an existing
archive ceiling with `max-bytes`; the default is 64 MiB. `deadline-ms` defaults to
180000 and bounds all transport attempts together.

The URL must identify an exact asset under
`https://github.com/OWNER/REPO/releases/download/TAG/NAME`. The downloader derives
the API release lookup and requires exactly one asset with that name. It sends
the token only to `api.github.com`. An API redirect may target the GitHub release
asset CDN, where the request carries no token. A missing token refuses fallback.

An HTTP 200 response with the wrong SHA256 fails immediately. API errors,
ambiguous metadata, untrusted redirects, and missing pins refuse acquisition.
Only verified bytes replace the destination. The downloader does not implement
an anonymous public-release availability check.

## Use from Harn

The `burin-ci-checks/release_asset` export provides `acquire(transport, asset,
token)`. `transport` contains only the network and clock handles. `asset` contains
`url`, `sha256`, `max_bytes`, and `deadline_ms`. The result contains verified
`data` bytes and a `route` of `browser` or `asset_api`.

## Regenerate the reusable workflow

The reusable cargo-deny workflow checks out its caller's source. Its preparation
step therefore embeds the exact downloader and shared tool installer sources.
The projection test compares both copies to their owners. After editing either
source, run from this repository root:

```sh
RELEASE_ASSET_WRITE=1 harn run --standalone --no-sandbox scripts/release-asset/projection.harn
```

Run the `scripts/release-asset` and `scripts/workflow-policy/cargo_deny_test.harn`
tests on Linux. The cargo-audit controls execute the actual preparation and
installation steps with the real owner CLI and mocked HTTP transport. They
require extraction and installation after API recovery and forbid both effects
after corrupt bytes or API refusal.
