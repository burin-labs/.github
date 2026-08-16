# frozen_string_literal: true

require "json"
require_relative "dependabot_waivers"

W = DependabotWaivers

def waiver(overrides = {})
  {
    "alert_number" => 2,
    "ghsa_id" => "GHSA-x744-4wpc-v9h2",
    "package" => "github.com/docker/docker",
    "ecosystem" => "go",
    "dismissed_reason" => "not_used",
    "why" => "The flaw executes in dockerd, not in the client library this repository links.",
    "review_by" => "2026-11-15",
    "observed" => {"severity" => "high", "fix_available" => false, "first_patched_version" => "29.3.1"}
  }.merge(overrides)
end

def document(waivers = [waiver])
  {"schema_version" => 1, "repository" => "burin-labs/burin-example-go", "waivers" => waivers}
end

def alert(overrides = {})
  {
    "number" => 2,
    "state" => "dismissed",
    "security_advisory" => {"ghsa_id" => "GHSA-x744-4wpc-v9h2", "severity" => "high"},
    "security_vulnerability" => {"first_patched_version" => {"identifier" => "29.3.1"}}
  }.merge(overrides)
end

def refuses(reason, &block)
  block.call
  abort "expected a SchemaError for #{reason}"
rescue W::SchemaError
  nil
end

# --- schema ---------------------------------------------------------------

W.validate!(document, repository: "burin-labs/burin-example-go")

refuses("a mismatched repository") { W.validate!(document, repository: "burin-labs/richtrack") }
refuses("an unversioned file") { W.validate!(document.merge("schema_version" => 99)) }
refuses("a duplicate alert number") { W.validate!(document([waiver, waiver])) }
refuses("an invented dismissal reason") { W.validate!(document([waiver("dismissed_reason" => "no_patch")])) }
refuses("a missing severity") { W.validate!(document([waiver("observed" => {"fix_available" => false, "first_patched_version" => nil})])) }

# A waiver has to carry its own justification, because GitHub has no dismissal
# reason meaning "upstream shipped no patch" -- the prose is the only place that
# fact can live.
refuses("an unexplained waiver") { W.validate!(document([waiver("why" => "no patch")])) }

# The registry must not be usable to hide work that can actually be done.
refuses("waiving an alert that has a fix") do
  W.validate!(document([waiver("observed" => {"severity" => "high", "fix_available" => true, "first_patched_version" => "11.1.1"})]))
end

# --- reconciliation -------------------------------------------------------

TODAY = "2026-08-15"

def verdict_of(waiver:, alert:, fix_installable:, today: TODAY)
  W.reconcile(waiver: waiver, alert: alert, fix_installable: fix_installable, today: today).first
end

abort "an unfixed alert must stay dismissed" unless
  verdict_of(waiver: waiver, alert: alert, fix_installable: false) == :ok

# The case this whole mechanism exists for: GitHub does not reopen manually
# dismissed alerts when a patch finally ships, so the audit has to.
abort "a newly installable fix must reopen the alert" unless
  verdict_of(waiver: waiver, alert: alert, fix_installable: true) == :reopen

# GHSA-x744-4wpc-v9h2 names "29.3.1", but no such version of the
# github.com/docker/docker module is published. Treating the advisory's claim as
# proof of a fix would reopen this alert on every run and rebuild the noise.
abort "an advisory patch claim alone must not reopen an alert" unless
  verdict_of(waiver: waiver, alert: alert, fix_installable: false) == :ok

abort "a severity increase must reopen the alert" unless
  verdict_of(waiver: waiver, alert: alert("security_advisory" => {"ghsa_id" => "GHSA-x744-4wpc-v9h2", "severity" => "critical"}), fix_installable: false) == :reopen

abort "a severity decrease must not reopen the alert" unless
  verdict_of(waiver: waiver, alert: alert("security_advisory" => {"ghsa_id" => "GHSA-x744-4wpc-v9h2", "severity" => "medium"}), fix_installable: false) == :ok

abort "a re-pointed alert must reopen" unless
  verdict_of(waiver: waiver, alert: alert("security_advisory" => {"ghsa_id" => "GHSA-other", "severity" => "high"}), fix_installable: false) == :reopen

abort "a vanished alert must go stale" unless
  verdict_of(waiver: waiver, alert: nil, fix_installable: false) == :stale

abort "a reopened alert must go stale" unless
  verdict_of(waiver: waiver, alert: alert("state" => "open"), fix_installable: false) == :stale

abort "a fixed alert must go stale" unless
  verdict_of(waiver: waiver, alert: alert("state" => "fixed"), fix_installable: false) == :stale

abort "an auto-dismissed alert is still validly waived" unless
  verdict_of(waiver: waiver, alert: alert("state" => "auto_dismissed"), fix_installable: false) == :ok

# A waiver is a dated claim, not a permanent mute. Once its review date passes
# the audit fails, which is what stops the registry becoming the new place
# noise accumulates unread.
abort "a lapsed review date must fail the audit" unless
  verdict_of(waiver: waiver, alert: alert, fix_installable: false, today: "2026-11-16") == :overdue

abort "reopening must win over an expired review date" unless
  verdict_of(waiver: waiver, alert: alert, fix_installable: true, today: "2026-11-16") == :reopen

# --- reporting ------------------------------------------------------------

summary = W.summarize([
  {"verdict" => "ok"}, {"verdict" => "reopen"}, {"verdict" => "stale"},
  {"verdict" => "overdue"}, {"verdict" => "unwaived"}
])
abort "summary must count every verdict" unless
  summary.values_at("checked", "ok", "reopened", "stale", "overdue", "unwaived") == [5, 1, 1, 1, 1, 1]

# --- unwaived dismissals --------------------------------------------------

# Once a repo has a registry it has opted into the policy, so a dismissal made
# outside the registry records no reason and never expires.
alerts = {2 => alert, 7 => alert("number" => 7), 9 => alert("number" => 9)}
abort "a dismissal outside the registry must be reported" unless
  W.unwaived(alerts: alerts, waivers: [waiver]).map { |a| a["number"] } == [7, 9]
abort "waived alerts must not be reported as unwaived" unless
  W.unwaived(alerts: {2 => alert}, waivers: [waiver]).empty?
abort "a repo with no dismissals has nothing unwaived" unless
  W.unwaived(alerts: {}, waivers: [waiver]).empty?

# --- registered waivers ---------------------------------------------------

# The template ships as the example a new repository copies, so it has to pass
# the same checker the real registries do.
template = File.expand_path("../templates/dependabot-waivers.json", __dir__)
W.validate!(JSON.parse(File.read(template)))

puts "dependabot waiver policy: ok"
