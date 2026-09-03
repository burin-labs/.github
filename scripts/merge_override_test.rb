# frozen_string_literal: true

require "json"
require "tmpdir"
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

event_pages = [[
  {"id" => 30, "event" => "labeled", "label" => {"name" => "bypass-ci"},
   "actor" => {"login" => "alice"}}
]]
assert MergeOverride.issue_events_from_pages(event_pages: event_pages).map { |event| event.fetch("id") } == [30],
       "issue-event pages must flatten through the request seam"
begin
  MergeOverride.issue_events_from_pages(event_pages: [[{"id" => 30}], [{"id" => 30}]])
  abort "issue-event pagination must reject duplicate event identities"
rescue MergeOverride::RequestError => error
  assert error.message.include?("duplicate event id"), error.message
end

run_selection = MergeOverride.select_competing_runs(
  current_run_id: 32891707758,
  current_workflow_id: 330242720,
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

empty_selection = MergeOverride.select_competing_runs(
  current_run_id: 999,
  current_workflow_id: 2,
  workflow_runs: []
)
assert empty_selection.fetch(:pending_count).zero?, empty_selection.inspect
assert empty_selection.fetch(:competing_run_ids).empty?, empty_selection.inspect

empty_census = MergeOverride.workflow_run_census_from_pages(run_pages: [
  {"total_count" => 0, "workflow_runs" => []}
])
assert empty_census.fetch(:workflow_runs).empty?, empty_census.inspect
assert empty_census.fetch(:reported_total).zero?, empty_census.inspect
assert empty_census.fetch(:page_count) == 1, empty_census.inspect

slurped_census = MergeOverride.workflow_run_census_from_pages(run_pages: [
  {"total_count" => 2, "workflow_runs" => [
    {"id" => 4, "workflow_id" => 8, "status" => "completed"},
    {"id" => 5, "workflow_id" => 9, "status" => "queued"}
  ]}
])
assert slurped_census.fetch(:workflow_runs).map { |run| run.fetch("id") } == [4, 5],
       slurped_census.inspect

begin
  MergeOverride.workflow_run_census_from_pages(run_pages: [{"total_count" => 1}])
  abort "run-page normalization must fail closed when workflow_runs is absent"
rescue MergeOverride::RunSelectionError => error
  assert error.message.include?("omitted workflow_runs"), error.message
end

empty_status_pages = MergeOverride::ACTIVE_RUN_STATUSES.to_h do |status|
  [status, [{"total_count" => 0, "workflow_runs" => []}]]
end
active_census = MergeOverride.active_workflow_run_census_from_queries(
  status_pages: empty_status_pages
)
assert active_census.fetch(:workflow_runs).empty?, active_census.inspect
assert active_census.fetch(:query_count) == 5, active_census.inspect

requested_pages = empty_status_pages.merge(
  "requested" => [{
    "total_count" => 1,
    "workflow_runs" => [{"id" => 44, "workflow_id" => 55, "status" => "requested"}]
  }]
)
requested_selection = MergeOverride.select_competing_runs(
  current_run_id: 99,
  current_workflow_id: 66,
  workflow_runs: MergeOverride.active_workflow_run_census_from_queries(
    status_pages: requested_pages
  ).fetch(:workflow_runs)
)
assert requested_selection.fetch(:competing_run_ids) == [44], requested_selection.inspect

transition_pages = requested_pages.merge(
  "queued" => [{
    "total_count" => 1,
    "workflow_runs" => [{"id" => 44, "workflow_id" => 55, "status" => "queued"}]
  }]
)
transition_census = MergeOverride.active_workflow_run_census_from_queries(
  status_pages: transition_pages
)
assert transition_census.fetch(:workflow_runs).length == 1, transition_census.inspect
assert transition_census.fetch(:workflow_runs).fetch(0).fetch("status") == "queued",
       transition_census.inspect

begin
  MergeOverride.workflow_run_census_from_pages(run_pages: [
    {"total_count" => 2, "workflow_runs" => [
      {"id" => 44, "workflow_id" => 55, "status" => "queued"},
      {"id" => 44, "workflow_id" => 55, "status" => "queued"}
    ]}
  ])
  abort "one status query must reject duplicate pagination identities"
rescue MergeOverride::RunSelectionError => error
  assert error.message.include?("duplicate run id within one status query"), error.message
end

begin
  MergeOverride.workflow_run_census_from_pages(run_pages: [
    {"total_count" => 2, "workflow_runs" => [{"id" => 1}]}
  ])
  abort "run-page normalization must fail closed on a partial census"
rescue MergeOverride::RunSelectionError => error
  assert error.message.include?("measured 1 of 2"), error.message
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

Dir.mktmpdir("merge-override-events") do |dir|
  labels_path = File.join(dir, "labels.json")
  events_path = File.join(dir, "events.json")
  File.write(labels_path, JSON.generate(["bypass-ci"]))
  File.write(events_path, JSON.generate([[
    {"id" => 31, "event" => "labeled", "label" => {"name" => "bypass-ci"},
     "actor" => {"login" => "alice"}, "padding" => "x" * 160_000}
  ]]))
  resolved_out = IO.popen(
    ["ruby", File.expand_path("merge_override.rb", __dir__), "resolve-request", labels_path, events_path],
    "r"
  ) do |io|
    io.read
  end
  assert $?.success?, "resolve-request CLI must accept event pages larger than ARG_MAX via files"
  assert JSON.parse(resolved_out).fetch("label") == "bypass-ci", resolved_out
end

# This payload is larger than Linux's 131,072-byte maximum for one argv entry.
# It must remain ordinary file data and still reach the public CLI seam.
selection_out = Dir.mktmpdir("merge-override-runs") do |run_pages_dir|
  MergeOverride::ACTIVE_RUN_STATUSES.each do |status|
    pages = if status == "requested"
      [{
        "total_count" => 1,
        "workflow_runs" => [
          {"id" => 70, "workflow_id" => 80, "status" => status, "padding" => "x" * 160_000}
        ]
      }]
    else
      [{"total_count" => 0, "workflow_runs" => []}]
    end
    File.write(File.join(run_pages_dir, "#{status}.json"), JSON.generate(pages))
  end
  IO.popen(
    ["ruby", File.expand_path("merge_override.rb", __dir__), "select-runs", "70", "80", run_pages_dir],
    "r"
  ) do |io|
    io.read
  end
end
assert $?.success?, "select-runs CLI must accept a document larger than ARG_MAX via files"
oversized_selection = JSON.parse(selection_out)
assert oversized_selection.fetch("pending_count").zero?, oversized_selection.inspect

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
sweep = steps.find { |step| step["name"] == "Cancel competing workflow runs" }.fetch("run")
assert sweep.include?('run_pages_dir="$(mktemp -d)"'), "unbounded page documents must use files"
assert !sweep.include?("--argjson workflow_runs"), "workflow-run payloads must never enter argv"
assert sweep.include?("status=\${status}"), "completed history must not crowd active runs out of the census"
assert sweep.include?('pending_count=unmeasured'),
       "the audit must distinguish an unmeasured sweep from a measured zero"
assert sweep.include?("current override workflow identity"),
       "current-run identity failures must be reported separately"
assert sweep.include?("workflow runs for the pull-request head"),
       "census failures must name the failing stage"
assert sweep.include?("could not select competing workflow runs"),
       "selector failures must name the failing stage"
request_step = steps.find { |step| step["name"] == "Resolve attached override request" }.fetch("run")
cleanup_step = steps.find { |step| step["name"] == "Remove consumed override labels" }.fetch("run")
[request_step, cleanup_step].each do |script|
  assert !script.include?("--argjson event_pages"), "issue-event payloads must never enter argv"
  assert script.include?('event_pages_file="$(mktemp)"'), "issue-event pages must use a file"
  assert script.include?("merge_override.rb resolve-request"),
         "request resolution must use the shared Ruby normalization seam"
end
cleanup = steps.find { |step| step["name"] == "Remove consumed override labels" }
assert cleanup&.fetch("if") == "always()", "terminal label cleanup must run on refused and errored attempts"
audit = steps.find { |step| step["name"] == "Audit terminal outcome" }
assert audit&.fetch("if") == "always()", "every terminal attempt must be audited"

puts "merge_override_test.rb: ok"
