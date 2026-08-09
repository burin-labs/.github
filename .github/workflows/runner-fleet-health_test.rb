# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"
require "yaml"

root = File.expand_path("../..", __dir__)
workflow = YAML.safe_load(File.read(File.join(__dir__, "runner-fleet-health.yml")), aliases: true)
events = workflow.fetch(true)
abort "runner observer must run hourly" unless events.dig("schedule", 0, "cron") == "23 * * * *"
abort "runner observer must remain manually runnable" unless events.key?("workflow_dispatch")
job = workflow.fetch("jobs").fetch("observe")
abort "runner observer must stay on a small bounded job" unless job.fetch("runs-on") == "ubuntu-latest" && job.fetch("timeout-minutes") == 5

steps = job.fetch("steps")
token = steps.find { |step| step["name"] == "Mint read-only release-app token" }
unless token&.dig("with", "permission-organization-self-hosted-runners") == "read"
  abort "runner observer token must be read-only for self-hosted runner inventory"
end
observer = steps.find { |step| step["name"] == "Observe two consecutive fleet snapshots" }
run = observer&.fetch("run", "")
abort "runner observer must take two snapshots" unless run.scan("snapshot \"").length == 2
abort "runner observer must honor the typed probe interval" unless run.include?("sleep \"$interval\"")

policy = JSON.parse(File.read(File.join(root, ".github", "runner-fleet.json")))
expected = policy.fetch("expected_runners")
abort "runner policy must be versioned" unless policy.fetch("schema_version") == 1
abort "runner policy must not contain duplicate names" unless expected.uniq == expected
abort "runner policy must cover the current thirteen-runner fleet" unless expected.length == 13

script = File.join(root, "scripts", "runner-fleet-health.sh")
Dir.mktmpdir do |tmp|
  healthy_first = expected.map { |name| {"name" => name, "status" => "online", "busy" => false} }
  healthy_second = Marshal.load(Marshal.dump(healthy_first))
  healthy_first.find { |runner| runner["name"] == "cattrick-w2" }["status"] = "offline"
  File.write(File.join(tmp, "first.json"), JSON.generate(healthy_first))
  File.write(File.join(tmp, "second.json"), JSON.generate(healthy_second))

  out, status = Open3.capture2e(script, "evaluate", File.join(tmp, "first.json"), File.join(tmp, "second.json"))
  abort "a transient one-probe disconnect must recover" unless status.success? && JSON.parse(out).fetch("ok")

  healthy_second.find { |runner| runner["name"] == "cattrick-w2" }["status"] = "offline"
  File.write(File.join(tmp, "second.json"), JSON.generate(healthy_second))
  out, status = Open3.capture2e(script, "evaluate", File.join(tmp, "first.json"), File.join(tmp, "second.json"))
  report = JSON.parse(out)
  abort "a sustained offline runner must fail" if status.success?
  abort "sustained failure must name the runner" unless report.fetch("unhealthy").map { |entry| entry.fetch("name") } == ["cattrick-w2"]
end

puts "runner fleet health policy: ok"
