# frozen_string_literal: true

require "yaml"

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
  next if preceding.any? { |candidate| candidate.strip == "report_unmeasured" }

  abort "#{path}: `exit 0` on line #{index + 1} of the detect script must be preceded by report_unmeasured"
end

puts "runner-availability policy: ok"
