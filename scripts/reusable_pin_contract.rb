# frozen_string_literal: true

require "json"
require "yaml"

# Structural YAML queries used by the network-owning reusable workflow audit.
module ReusablePinContract
  OUTPUT_NAME = /[A-Za-z_][A-Za-z0-9_-]*/

  module_function

  def document(source)
    YAML.safe_load(source, aliases: true) || {}
  end

  def scalar_strings(value, strings = [])
    case value
    when Hash
      value.each_value { |child| scalar_strings(child, strings) }
    when Array
      value.each { |child| scalar_strings(child, strings) }
    when String
      strings << value
    end
    strings
  end

  def outputs_read(strings, job_id)
    job = Regexp.escape(job_id)
    output = OUTPUT_NAME.source
    patterns = [
      /needs\.#{job}\.outputs\.(#{output})/,
      /needs\.#{job}\.outputs\[['"](#{output})['"]\]/,
      /needs\[['"]#{job}['"]\]\.outputs\.(#{output})/,
      /needs\[['"]#{job}['"]\]\.outputs\[['"](#{output})['"]\]/
    ]
    strings.flat_map { |text| patterns.flat_map { |pattern| text.scan(pattern).flatten } }.uniq.sort
  end

  def uses_line(source, reference, claimed_lines)
    pattern = /^\s*uses:\s*['"]?#{Regexp.escape(reference)}['"]?\s*(?:#.*)?$/
    lines = source.lines
    index = lines.each_index.find do |candidate|
      !claimed_lines.include?(candidate) && lines[candidate].match?(pattern)
    end
    raise "could not locate reusable workflow reference #{reference.inspect}" unless index

    claimed_lines << index
    index + 1
  end

  def references(source, org:, policy_repo:)
    parsed = document(source)
    jobs = parsed.fetch("jobs", {})
    strings = scalar_strings(parsed)
    prefix = "#{org}/#{policy_repo}/"
    reference_pattern = %r{\A#{Regexp.escape(prefix)}(\.github/workflows/[A-Za-z0-9._-]+\.ya?ml)@([^\s'"#]+)\z}
    claimed_lines = []

    jobs.each_with_object([]) do |(job_id, job), references|
      next unless job.is_a?(Hash) && job["uses"].is_a?(String)

      match = reference_pattern.match(job["uses"])
      next unless match

      references << {
        job: job_id.to_s,
        workflow: match[1],
        ref: match[2],
        line: uses_line(source, job["uses"], claimed_lines),
        required_outputs: outputs_read(strings, job_id.to_s)
      }
    end
  end

  def declared_outputs(source)
    parsed = document(source)
    triggers = parsed["on"] || parsed[true]
    workflow_call = triggers.is_a?(Hash) ? triggers["workflow_call"] : nil
    outputs = workflow_call.is_a?(Hash) ? workflow_call["outputs"] : nil
    outputs.is_a?(Hash) ? outputs.keys.map(&:to_s).sort : []
  end
end

if $PROGRAM_NAME == __FILE__
  command = ARGV.shift
  source = $stdin.read

  result = case command
           when "references"
             org = ARGV.shift
             policy_repo = ARGV.shift
             abort "usage: reusable_pin_contract.rb references ORG POLICY_REPO" unless org && policy_repo
             ReusablePinContract.references(source, org: org, policy_repo: policy_repo)
           when "declared-outputs"
             ReusablePinContract.declared_outputs(source)
           else
             abort "usage: reusable_pin_contract.rb references ORG POLICY_REPO | declared-outputs"
           end

  puts JSON.generate(result)
end
