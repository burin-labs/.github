# frozen_string_literal: true

require "json"

def fail_contract(message)
  warn "::error::#{message}"
  exit 1
end

begin
  results = JSON.parse(ENV.fetch("NEEDS_RESULTS_JSON"))
rescue KeyError, JSON::ParserError
  fail_contract("results-json must be a valid dependency-result array")
end

unless results.is_a?(Array) && !results.empty?
  fail_contract("results-json must contain at least one CI dependency result")
end

invalid = results.each_with_object(Hash.new(0)) do |result, failures|
  next if result == "success"

  label = result.is_a?(String) && !result.empty? ? result : "malformed"
  failures[label] += 1
end

unless invalid.empty?
  summary = invalid.sort.map { |result, count| "#{result}=#{count}" }.join(", ")
  fail_contract("required CI dependencies did not succeed: #{summary}")
end

puts "required CI dependencies succeeded: #{results.length}"
