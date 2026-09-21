# frozen_string_literal: true

require "yaml"
require "json"
require "tmpdir"
require "open3"

path = File.join(__dir__, "runner-availability.yml")
document = YAML.safe_load(File.read(path), aliases: true)

# Psych follows YAML 1.1 and may decode the unquoted GitHub key `on` as true.
triggers = document["on"] || document[true]
abort "#{path}: workflow must be reusable" unless triggers.is_a?(Hash) && triggers.key?("workflow_call")

job = document.fetch("jobs").fetch("detect")
declared = triggers.fetch("workflow_call").fetch("outputs").keys.sort
exposed = job.fetch("outputs").keys.sort

# A job output that is never declared at the workflow_call level is invisible to
# callers, and a declared output with no job output behind it resolves to the
# empty string. Neither fails the detector; both fail somewhere in the caller's
# `runs-on`, far from the cause.
abort "#{path}: workflow_call outputs #{declared} must match job outputs #{exposed}" unless declared == exposed

script = job.fetch("steps").find { |step| step["id"] == "detect" }.fetch("run")

inputs = triggers.fetch("workflow_call").fetch("inputs")
probe_input = inputs.fetch("linux_probe_runner_tag")
abort "#{path}: Linux probe input must default to empty" unless probe_input.fetch("default") == ""

# `selfhosted_disabled` is deliberately published once, before any exit path,
# precisely so the early exits do not each have to remember it. Every other
# output has to be written by the shared no-capacity reporter.
WRITTEN_BEFORE_ANY_EXIT = ["selfhosted_disabled"].freeze

reporter = script[/^\s*report_unmeasured\(\)\s*\{(.*?)^\s*\}/m]
abort "#{path}: detector must funnel no-capacity exits through report_unmeasured" unless reporter

(declared - WRITTEN_BEFORE_ANY_EXIT).each do |output|
  next if reporter.include?("#{output}=")

  abort "#{path}: report_unmeasured must publish #{output}, or an early exit ships a partial output set"
end

# The optional probe must preserve the distinction between no requested
# measurement and a measured pool with zero online runners. The former belongs
# in the shared unmeasured receipt; the latter must flow through the same label
# matcher as every other capacity lane.
abort "#{path}: unmeasured capacity must include linux_probe" unless reporter.include?('"linux_probe"')
abort "#{path}: absent Linux probe must be recorded as unmeasured" unless script.include?(
  'record_capacity linux_probe 0 0 false'
)
abort "#{path}: requested Linux probe must use the shared label matcher" unless script.include?(
  'probe_online="$(count_matching Linux "$LINUX_PROBE_TAG" any)"'
)

# GITHUB_OUTPUT is append-only and read once when the step ends, so an exit path
# that skips the reporter cannot fail loudly - it silently emits fewer keys than
# it declares. Keep every exit adjacent to the reporter that fills them in.
lines = script.lines.map(&:rstrip)
lines.each_with_index do |line, index|
  next unless line.strip == "exit 0"

  preceding = lines[0...index].reject { |candidate| candidate.strip.empty? }.last(2)
  next if preceding.any? { |candidate| candidate.strip.start_with?("report_unmeasured") }

  abort "#{path}: `exit 0` on line #{index + 1} of the detect script must be preceded by report_unmeasured"
end

# The structural checks above prove the reporter writes every key. They cannot
# prove which reason a given credentials state produces, and that is the whole
# point of the Dependabot carve-out: the same "no token" condition must route a
# private repository onto the fleet and a public one onto hosted runners. So
# run the real script text under each state and read the outputs it emits.
require "open3"
require "tmpdir"

def rehearse(script, env)
  Dir.mktmpdir do |dir|
    script_path = File.join(dir, "detect.sh")
    output_path = File.join(dir, "github_output")
    File.write(script_path, script)
    File.write(output_path, "")
    base = {
      "GITHUB_OUTPUT" => output_path, "GH_TOKEN" => "", "OWNER" => "burin-labs",
      "DEFAULT_TAG" => "harn-ci", "LINUX_TAG" => "harn-ci", "LINUX_BIG_TAG" => "harn-ci-big",
      "LINUX_FETCH_TAG" => "harn-fetch-ok", "LINUX_PROBE_TAG" => "", "MACOS_TAG" => "harn-ci",
      "WINDOWS_TAG" => "harn-ci", "RUNNER_GROUPS" => "Default", "SELFHOSTED_DISABLED" => "",
      "MINIMUM_ONLINE" => "1", "MINIMUM_ONLINE_BY_POOL" => "{}"
    }
    _, stderr, status = Open3.capture3(base.merge(env), "bash", script_path)
    abort "rehearsal exited #{status.exitstatus}: #{stderr}" unless status.success?
    File.read(output_path).lines.map(&:strip).reject(&:empty?).to_h { |l| l.split("=", 2) }
  end
end

def expect(outputs, key, value, message)
  return if outputs[key] == value

  abort "#{message}: expected #{key}=#{value}, got #{key}=#{outputs[key].inspect}"
end

DEPENDABOT = "dependabot[bot]"

private_bump = rehearse(script, "IS_DEPENDABOT_ACTOR" => "true", "REPOSITORY_PRIVATE" => "true")
expect(private_bump, "probe_state", "probe_unavailable:dependabot_secret_store",
       "a private Dependabot bump must name the credentials state, not claim the fleet is unmeasured")
expect(private_bump, "selfhosted_permitted", "true",
       "a private Dependabot bump must be allowed onto the fleet")
expect(private_bump, "linux", "true",
       "a private Dependabot bump must offer the Linux lane")

public_bump = rehearse(script, "IS_DEPENDABOT_ACTOR" => "true", "REPOSITORY_PRIVATE" => "false")
expect(public_bump, "probe_state", "probe_unavailable:dependabot_secret_store",
       "a public Dependabot bump must still name the credentials state")
expect(public_bump, "selfhosted_permitted", "false",
       "a public repository must keep falling through to hosted runners")
expect(public_bump, "linux", "false",
       "a public Dependabot bump must not be offered the fleet")

# A fork pull request is not Dependabot and must be untouched by the carve-out.
fork_pr = rehearse(script, "IS_DEPENDABOT_ACTOR" => "false", "REPOSITORY_PRIVATE" => "false")
expect(fork_pr, "probe_state", "unmeasured",
       "a tokenless non-Dependabot run must stay plain unmeasured")
expect(fork_pr, "selfhosted_permitted", "false", "a fork must never reach the fleet")

# A private repo alone must not open the fleet; the carve-out is Dependabot-only.
private_human = rehearse(script, "IS_DEPENDABOT_ACTOR" => "false", "REPOSITORY_PRIVATE" => "true")
expect(private_human, "probe_state", "unmeasured",
       "a tokenless human run on a private repo is still an unmeasured probe")
expect(private_human, "selfhosted_permitted", "false",
       "repository visibility alone must not permit the fleet")

# THE case this file gained for #112. The kill switch and the probe credentials
# are independent, and only the measured path used to ask about the switch. A
# run with no credentials and one operating system retired published that
# operating system as available, and a caller keying `runs-on` on the boolean
# routed onto the retired pool. The whole-fleet shortcut hid it: that fires only
# when EVERY operating system is disabled, so a partial switch fell through.
#
# Asserted on both the boolean and the capacity entry, because a consumer that
# reads the typed state first and one that still reads the boolean must both
# stay on hosted capacity.
disabled_bump = rehearse(
  script,
  "IS_DEPENDABOT_ACTOR" => "true", "REPOSITORY_PRIVATE" => "true",
  "SELFHOSTED_DISABLED" => "linux"
)
expect(disabled_bump, "linux", "false",
       "an unmeasured run must not offer a lane the kill switch retired")
expect(disabled_bump, "linux_big", "false", "linux implies its big subset")
expect(disabled_bump, "linux_fetch", "false", "linux implies its fetch subset")
expect(disabled_bump, "linux_probe", "false", "linux implies its probe subset")
expect(disabled_bump, "macos", "true",
       "the switch is per operating system; an untouched lane must stay offered")
expect(disabled_bump, "selfhosted_disabled", "linux,linux_big,linux_fetch",
       "the retired set must still be published for the caller to read")
# The probe genuinely was unavailable, so the typed state must keep saying so.
# Renaming it here would break every consumer that refuses a state it does not
# know, which is the correct behaviour for those consumers.
expect(disabled_bump, "probe_state", "probe_unavailable:dependabot_secret_store",
       "the switch does not change why the probe could not run")
capacity = JSON.parse(disabled_bump.fetch("capacity"))
abort "a retired lane must be ineligible in capacity too" if capacity.fetch("linux").fetch("eligible")
abort "an untouched lane must stay eligible in capacity" unless capacity.fetch("macos").fetch("eligible")
abort "nothing was counted, so no lane may claim a measurement" if capacity.values.any? { |lane| lane.fetch("measured") }

# A switch naming a lane nobody asked about must not disturb the others, and a
# caller that is not permitted at all stays false whatever the switch says.
macos_only = rehearse(
  script,
  "IS_DEPENDABOT_ACTOR" => "true", "REPOSITORY_PRIVATE" => "true",
  "SELFHOSTED_DISABLED" => "macos"
)
expect(macos_only, "macos", "false", "the named lane must be retired")
expect(macos_only, "linux", "true", "an unnamed lane must be untouched")

forbidden = rehearse(
  script,
  "IS_DEPENDABOT_ACTOR" => "true", "REPOSITORY_PRIVATE" => "false",
  "SELFHOSTED_DISABLED" => "macos"
)
expect(forbidden, "linux", "false",
       "a caller that may not use the fleet stays off it whatever the switch names")

# The three states must stay distinguishable; collapsing any two is the defect.
states = [private_bump, public_bump, fork_pr].map { |o| [o["probe_state"], o["selfhosted_permitted"]] }
abort "probe_state and selfhosted_permitted must distinguish all three cases" unless states.uniq.length == 3

puts "runner-availability policy: ok"

# Exercise the actual workflow script with API-shaped fixtures, including the
# decision consumed by runs-on. Counting matching text cannot prove fallback.
Dir.mktmpdir("runner-availability-test") do |dir|
  File.write(File.join(dir, "gh"), <<~SH)
    #!/usr/bin/env bash
    case "$*" in
      *runner-groups/1/runners*) cat "$RUNNER_FIXTURE" ;;
      *runner-groups*) echo '[{"runner_groups":[{"name":"Default","id":1}]}]' ;;
      *) exit 91 ;;
    esac
  SH
  File.chmod(0755, File.join(dir, "gh"))
  runner = lambda do |id, status, busy, labels|
    {id: id, name: "worker-#{id}", status: status, busy: busy,
     labels: labels.map { |label| {name: label} }}
  end
  labels = ["self-hosted", "Linux", "X64", "stable", "big", "fetch", "identity"]
  healthy = (1..3).map { |id| runner.call(id, "online", false, labels) }
  cases = {
    "minimum met" => [healthy, "true", true, 3, true],
    "label removed" => [healthy.map { |r| r[:id] == 3 ? runner.call(3, "online", false, labels - ["stable"]) : r }, "false", false, 2, true],
    "offline" => [healthy.map { |r| r[:id] == 3 ? runner.call(3, "offline", false, labels) : r }, "false", false, 2, true],
    "busy but eligible" => [healthy.map { |r| r.merge(busy: true) }, "false", true, 3, true],
    "empty inventory" => [[], "false", false, 0, false]
  }
  cases.each do |name, (runners, available, eligible, online, measured)|
    fixture = File.join(dir, "runners.json")
    output = File.join(dir, "output")
    File.write(fixture, JSON.generate([{runners: runners}]))
    File.write(output, "")
    env = {"PATH" => "#{dir}:#{ENV.fetch('PATH')}", "GH_TOKEN" => "fixture",
           "OWNER" => "fixture", "RUNNER_GROUPS" => "Default", "DEFAULT_TAG" => "stable",
           "LINUX_TAG" => "stable", "LINUX_BIG_TAG" => "big", "LINUX_FETCH_TAG" => "fetch",
           "LINUX_PROBE_TAG" => "identity", "MACOS_TAG" => "stable", "WINDOWS_TAG" => "stable",
           "MINIMUM_ONLINE" => "3", "MINIMUM_ONLINE_BY_POOL" => "{}",
           "SELFHOSTED_DISABLED" => "", "RUNNER_FIXTURE" => fixture,
           "GITHUB_OUTPUT" => output, "TMPDIR" => dir}
    stdout, stderr, status = Open3.capture3(env, "bash", "-c", script)
    abort "#{name}: detector failed: #{stdout} #{stderr}" unless status.success?
    values = File.readlines(output).map { |line| line.strip.split("=", 2) }.to_h
    capacity = JSON.parse(values.fetch("capacity")).fetch("linux")
    abort "#{name}: wrong routing #{values}" unless values.fetch("linux") == available &&
      capacity.fetch("eligible") == eligible && capacity.fetch("online") == online &&
      capacity.fetch("measured") == measured
    if name == "label removed"
      abort "fetch subset must also refuse starvation" unless values.fetch("linux_fetch") == "false"
      abort "independent big pool should remain available" unless values.fetch("linux_big") == "true"
      abort "starvation must be named" unless stdout.include?("FLEET_RUNNER_LABEL_STARVED")
    end
    next unless name == "minimum met"

    macs = (4..5).map { |id| runner.call(id, "online", false, ["self-hosted", "macOS", "stable"]) }
    File.write(fixture, JSON.generate([{runners: runners + macs}]))
    [2, 3].each do |minimum|
      File.write(output, "")
      stdout, stderr, status = Open3.capture3(env.merge("MINIMUM_ONLINE_BY_POOL" => JSON.generate(macos: minimum)), "bash", "-c", script)
      abort "pool override failed: #{stdout} #{stderr}" unless status.success?
      values = File.readlines(output).map { |line| line.strip.split("=", 2) }.to_h
      expected = minimum == 2
      abort "macOS override did not control routing" unless values.fetch("macos") == expected.to_s &&
        JSON.parse(values.fetch("capacity")).fetch("macos").fetch("eligible") == expected
      abort "macOS override changed Linux routing" unless values.fetch("linux") == "true"
    end
    ['{"macos":0}', '{"macos":1.5}', '{"typo":2}', '[]', '{"macos":"2"}'].each do |invalid|
      _, _, status = Open3.capture3(env.merge("MINIMUM_ONLINE_BY_POOL" => invalid), "bash", "-c", script)
      abort "invalid pool policy was accepted: #{invalid}" if status.success?
    end
  end
end
puts "runner-availability decisions: shared, per-pool, and invalid-policy fixtures passed"
