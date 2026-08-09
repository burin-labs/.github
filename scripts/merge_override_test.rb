# frozen_string_literal: true

require "json"
require_relative "merge_override"

def assert(condition, message)
  abort message unless condition
end

assert MergeOverride.known_label?("force-merge"), "force-merge must be known"
assert !MergeOverride.known_label?("no-changelog-needed"), "unrelated labels must stay out of scope"

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

bypass_ci = MergeOverride.plan(label: "bypass-ci", ci_status_conclusion: "failure")
assert bypass_ci == {
  cancel_workflows: true,
  publish_ci_status: true,
  merge: false,
  require_ci_green: false
}, "bypass-ci plan drifted: #{bypass_ci.inspect}"

begin
  MergeOverride.plan(label: "bypass-merge-queue", ci_status_conclusion: "failure")
  abort "bypass-merge-queue must require green CI"
rescue MergeOverride::PlanError => error
  assert error.message.include?("CI status"), error.message
end

queue = MergeOverride.plan(label: "bypass-merge-queue", ci_status_conclusion: "success")
assert queue.fetch(:merge), "bypass-merge-queue must merge"
assert !queue.fetch(:publish_ci_status), "bypass-merge-queue must not fake CI"

force = MergeOverride.plan(label: "force-merge", ci_status_conclusion: "failure")
assert force.fetch(:merge), "force-merge must merge"
assert force.fetch(:publish_ci_status), "force-merge must publish CI status"
assert force.fetch(:cancel_workflows), "force-merge must cancel competing runs"

body = MergeOverride.audit_body(label: "force-merge", actor: "kennethsinder", plan: force)
assert body.include?("`force-merge`"), body
assert body.include?("@kennethsinder"), body

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

plan_json = {"label" => "bypass-ci", "ci_status_conclusion" => "failure"}
plan_out = IO.popen(["ruby", File.expand_path("merge_override.rb", __dir__), "plan"], "r+") do |io|
  io.write(JSON.generate(plan_json))
  io.close_write
  io.read
end
assert $?.success?, "plan CLI exit status"
parsed = JSON.parse(plan_out)
assert parsed.fetch("cancel_workflows") == true, "plan CLI must emit JSON"

puts "merge_override_test.rb: ok"
