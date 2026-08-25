# frozen_string_literal: true

require "json"
require "yaml"
require_relative "merge_override"

def assert(condition, message)
  abort message unless condition
end

assert MergeOverride.known_label?("force-merge"), "force-merge must be known"
assert !MergeOverride.known_label?("no-changelog-needed"), "unrelated labels must stay out of scope"

request = MergeOverride.resolve_request(
  attached_labels: %w[bypass-ci bypass-merge-queue force-merge unrelated],
  events: [
    {"id" => 10, "event" => "labeled", "label" => {"name" => "bypass-ci"}, "actor" => {"login" => "alice"}},
    {"id" => 11, "event" => "labeled", "label" => {"name" => "bypass-merge-queue"}, "actor" => {"login" => "alice"}},
    {"id" => 12, "event" => "labeled", "label" => {"name" => "force-merge"}, "actor" => {"login" => "alice"}}
  ]
)
assert request.fetch(:label) == "force-merge", "all labels must coalesce to force-merge: #{request.inspect}"
assert request.fetch(:labels) == %w[bypass-ci bypass-merge-queue force-merge], request.inspect
assert request.fetch(:actors) == ["alice"], request.inspect
assert request.fetch(:label_events) == {"bypass-ci" => 10, "bypass-merge-queue" => 11, "force-merge" => 12}, request.inspect
assert MergeOverride.cancellation_required?("force-merge"), "force-merge must sweep CI"
assert !MergeOverride.cancellation_required?("bypass-merge-queue"), "merge-queue bypass must preserve completed CI"

# The label event history is the authority for who requested every consumed
# label. A workflow queued behind another attempt must not attribute labels to
# whichever event happened to survive GitHub's pending-run replacement.
mixed_actor_request = MergeOverride.resolve_request(
  attached_labels: %w[bypass-ci force-merge],
  events: [
    {"id" => 20, "event" => "labeled", "label" => {"name" => "bypass-ci"}, "actor" => {"login" => "alice"}},
    {"id" => 21, "event" => "labeled", "label" => {"name" => "force-merge"}, "actor" => {"login" => "mallory"}}
  ]
)
assert mixed_actor_request.fetch(:actors) == %w[alice mallory], mixed_actor_request.inspect

run_selection = MergeOverride.select_competing_runs(
  current_run_id: 32891707758,
  workflow_runs: [
    {"id" => 32891707758, "workflow_id" => 330242720, "status" => "in_progress"},
    {"id" => 32891708681, "workflow_id" => 330242720, "status" => "in_progress"},
    {"id" => 32891709080, "workflow_id" => 330242720, "status" => "queued"},
    {"id" => 32891562018, "workflow_id" => 254475740, "status" => "in_progress"},
    {"id" => 32891561102, "workflow_id" => 335319300, "status" => "completed"}
  ]
)
assert run_selection.fetch(:override_run_ids) == [32891708681, 32891709080], run_selection.inspect
assert run_selection.fetch(:competing_run_ids) == [32891562018], run_selection.inspect

begin
  MergeOverride.select_competing_runs(
    current_run_id: 999,
    workflow_runs: [{"id" => 1, "workflow_id" => 2, "status" => "in_progress"}]
  )
  abort "run selection must fail closed when the current workflow id was not measured"
rescue MergeOverride::RunSelectionError => error
  assert error.message.include?("current run"), error.message
end

assert MergeOverride.ci_state([]) == "missing", "an absent check must be missing"
assert MergeOverride.ci_state([
  {"name" => "CI status", "status" => "in_progress", "conclusion" => nil, "started_at" => "2026-08-25T19:47:21Z"}
]) == "in_flight", "an active check must not collapse to missing"
assert MergeOverride.ci_state([
  {"name" => "CI status", "status" => "completed", "conclusion" => "success", "completed_at" => "2026-08-25T19:48:03Z"}
]) == "success", "a completed check must expose its conclusion"
assert MergeOverride.ci_state([
  {"name" => "CI status", "status" => "completed", "conclusion" => "success", "completed_at" => "2026-08-25T19:48:03Z"},
  {"name" => "CI status", "status" => "in_progress", "conclusion" => nil, "completed_at" => nil,
   "started_at" => "2026-08-25T19:49:03Z"}
]) == "in_flight", "a newer active check must sort after an older completed check"

begin
  MergeOverride.authorize!(
    org: "burin-labs",
    actor: "alice",
    membership_role: "member",
    repository_permission: "write",
    head_repository: "burin-labs/harn",
    base_repository: "burin-labs/harn"
  )
  abort "non-admin must be rejected"
rescue MergeOverride::AuthorizationError => error
  assert error.message.include?("not an organization or repository admin"), error.message
end

begin
  MergeOverride.authorize!(
    org: "burin-labs",
    actor: "kennethsinder",
    membership_role: "admin",
    repository_permission: "admin",
    head_repository: "outsider/harn",
    base_repository: "burin-labs/harn"
  )
  abort "fork heads must be rejected"
rescue MergeOverride::AuthorizationError => error
  assert error.message.include?("fork"), error.message
end

# Org membership may be unreadable to GITHUB_TOKEN; repository admin still works.
MergeOverride.authorize!(
  org: "burin-labs",
  actor: "kennethsinder",
  membership_role: "none",
  repository_permission: "admin",
  head_repository: "burin-labs/harn",
  base_repository: "burin-labs/harn"
)

MergeOverride.authorize!(
  org: "burin-labs",
  actor: "kennethsinder",
  membership_role: "admin",
  repository_permission: "none",
  head_repository: "burin-labs/harn",
  base_repository: "burin-labs/harn"
)

bypass_ci = MergeOverride.plan(label: "bypass-ci", ci_status_state: "failure")
assert bypass_ci == {
  cancel_workflows: true,
  publish_ci_status: true,
  merge: false,
  require_ci_green: false
}, "bypass-ci plan drifted: #{bypass_ci.inspect}"

begin
  MergeOverride.plan(label: "bypass-merge-queue", ci_status_state: "failure")
  abort "bypass-merge-queue must require green CI"
rescue MergeOverride::PlanError => error
  assert error.message.include?("CI status"), error.message
end

begin
  MergeOverride.plan(label: "bypass-merge-queue", ci_status_state: "in_flight")
  abort "bypass-merge-queue must refuse while CI is in flight"
rescue MergeOverride::PlanError => error
  assert error.message.include?("still in flight"), error.message
  assert error.message.include?("re-apply `bypass-merge-queue`"), error.message
end

queue = MergeOverride.plan(label: "bypass-merge-queue", ci_status_state: "success")
assert queue.fetch(:merge), "bypass-merge-queue must merge"
assert !queue.fetch(:publish_ci_status), "bypass-merge-queue must not fake CI"

force = MergeOverride.plan(label: "force-merge", ci_status_state: "failure")
assert force.fetch(:merge), "force-merge must merge"
assert force.fetch(:publish_ci_status), "force-merge must publish CI status"
assert force.fetch(:cancel_workflows), "force-merge must cancel competing runs"

body = MergeOverride.audit_body(label: "force-merge", actor: "kennethsinder", plan: force)
assert body.include?("`force-merge`"), body
assert body.include?("@kennethsinder"), body

refusal = MergeOverride.terminal_audit_body(
  status: "refused",
  label: "bypass-merge-queue",
  consumed_labels: %w[bypass-ci bypass-merge-queue],
  removed_labels: %w[bypass-ci bypass-merge-queue],
  actors: ["kennethsinder"],
  reason: "CI status is still in flight",
  retry_action: "Wait for CI to finish, then re-apply `bypass-merge-queue`."
)
assert refusal.include?("Refused"), refusal
assert refusal.include?("CI status is still in flight"), refusal
assert refusal.include?("Removed labels: `bypass-ci`, `bypass-merge-queue`"), refusal
assert refusal.include?("re-apply `bypass-merge-queue`"), refusal

authorize_json = {
  "org" => "burin-labs",
  "actor" => "kennethsinder",
  "membership_role" => "none",
  "repository_permission" => "admin",
  "head_repository" => "burin-labs/harn",
  "base_repository" => "burin-labs/harn"
}
authorize_out = IO.popen(["ruby", File.expand_path("merge_override.rb", __dir__), "authorize"], "r+") do |io|
  io.write(JSON.generate(authorize_json))
  io.close_write
  io.read
end
assert $?.success?, "authorize CLI exit status"
assert authorize_out.strip == "authorized", "authorize CLI must succeed for admins"

plan_json = {"label" => "bypass-ci", "ci_status_state" => "failure"}
plan_out = IO.popen(["ruby", File.expand_path("merge_override.rb", __dir__), "plan"], "r+") do |io|
  io.write(JSON.generate(plan_json))
  io.close_write
  io.read
end
assert $?.success?, "plan CLI exit status"
parsed = JSON.parse(plan_out)
assert parsed.fetch("cancel_workflows") == true, "plan CLI must emit JSON"

workflow_path = File.expand_path("../.github/workflows/merge-override.yml", __dir__)
workflow = YAML.safe_load_file(workflow_path, aliases: true)
assert workflow.fetch("permissions").fetch("issues") == "write",
       "the reusable workflow must be able to read label actors and remove consumed labels"
concurrency = workflow.fetch("concurrency")
assert concurrency.fetch("cancel-in-progress") == false, "override runs must queue, never cancel the active attempt"
assert concurrency.fetch("group").include?("inputs.pr-number"), "override concurrency must be scoped per PR"

steps = workflow.fetch("jobs").fetch("apply").fetch("steps")
step_index = steps.each_with_index.to_h { |step, index| [step.fetch("name"), index] }
assert step_index.fetch("Cancel competing workflow runs") < step_index.fetch("Resolve CI status state"),
       "CI state must be read after the cancellation sweep"
cleanup = steps.find { |step| step["name"] == "Remove consumed override labels" }
assert cleanup&.fetch("if") == "always()", "terminal label cleanup must run on refused and errored attempts"
audit = steps.find { |step| step["name"] == "Audit terminal outcome" }
assert audit&.fetch("if") == "always()", "every terminal attempt must be audited"

puts "merge_override_test.rb: ok"
