<!--
Title: [Area] Sentence case description, for example "[CI] Fix flaky release runner probe".
Area is this repository's own directory-map tag; see AGENTS.md.

Body: 3-5 sentences, total. What changed, why, the one risk, how it was
verified — at the claim level, not a list of test commands (the Files and
Checks tabs already show those). One excellent short paragraph beats a long
checklist.
-->

Fixes the release runner health check reporting `unknown` for any runner that
finished a job in the last 60 seconds, because the liveness probe used a
stale cache entry instead of re-querying the runner. Fleet dashboards showed
false "down" flaps during every deploy window. The risk is a runner that is
genuinely down now reads as live for one cache TTL (30s) before the next
probe corrects it. Verified by replaying the last week's flap incidents
against the fixed probe and confirming zero remained, plus the runner-fleet
integration test.

Closes #123 items: 1, 2 | Single-ask: #123

🤖 Generated with [Claude Code](https://claude.com/claude-code)
