# frozen_string_literal: true

require "yaml"

workflow = YAML.safe_load(File.read(File.join(__dir__, "dependabot-waiver-audit.yml")), aliases: true)
events = workflow.fetch(true)

abort "the waiver audit must run on a schedule" unless events.dig("schedule", 0, "cron")
abort "the waiver audit must remain manually runnable" unless events.key?("workflow_dispatch")

job = workflow.fetch("jobs").fetch("audit")
abort "the waiver audit must stay a small bounded job" unless
  job.fetch("runs-on") == "ubuntu-latest" && job.fetch("timeout-minutes") == 10

# The audit is the only thing that reopens a manually dismissed alert, so it
# needs write on Dependabot alerts. If this silently degraded to read, every
# waiver would look healthy forever and nothing would ever come back.
steps = job.fetch("steps")
token = steps.find { |step| step["name"] == "Mint release-app token" }
abort "the waiver audit token must be able to reopen alerts" unless
  token&.dig("with", "permission-vulnerability-alerts") == "write"
abort "the waiver audit token must be able to read waiver files" unless
  token&.dig("with", "permission-contents") == "read"
# Omitting `repositories` is deliberate: the audit has to see every repository
# in the org, because a waiver in a repo nobody remembered is exactly the one
# that goes unread.
abort "the waiver audit must not be scoped to one repository" if token&.dig("with", "repositories")

# The job is deliberately unarmed until the app has the permission above.
# Assert the gate exists so nobody arms it by deleting the condition without
# noticing what it was protecting.
abort "the waiver audit must stay gated on an explicit opt-in variable" unless
  job.fetch("if").include?("vars.DEPENDABOT_WAIVER_AUDIT")

audit = steps.find { |step| step["name"] == "Reconcile waivers against live alerts" }
run = audit&.fetch("run", "")
abort "the waiver audit must actually reopen alerts, not just report" unless run.include?("--apply")
# `set -e` would abort on the audit's non-zero exit before the summary is
# written, hiding the reason the job failed -- which is the whole report.
abort "the waiver audit must not abort before writing its summary" if run.include?("set -euo pipefail")
abort "the waiver audit must propagate the script's exit code" unless run.include?('exit "$result"')

puts "dependabot waiver audit workflow: ok"
