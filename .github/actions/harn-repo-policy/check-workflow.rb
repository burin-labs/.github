# frozen_string_literal: true

require "yaml"

path = ARGV.fetch(0)
document = YAML.safe_load(File.read(path), aliases: true)
abort "#{path}: workflow must be a mapping" unless document.is_a?(Hash)

# Psych follows YAML 1.1 and may decode the unquoted GitHub key `on` as true.
triggers = document["on"] || document[true]
abort "#{path}: workflow must declare merge_group" unless triggers.is_a?(Hash) && triggers.key?("merge_group")

jobs = document["jobs"]
abort "#{path}: workflow must declare jobs" unless jobs.is_a?(Hash)

package_jobs = jobs.each_with_object([]) do |(name, job), matches|
  next unless job.is_a?(Hash)

  reusable = job["uses"]
  next unless reusable.is_a?(String)
  next unless reusable.match?(%r{\Aburin-labs/\.github/\.github/workflows/harn-package\.yml@[0-9a-f]{40,64}\z})

  matches << name
end
abort "#{path}: no immutable call to the organization Harn package workflow" if package_jobs.empty?
abort "#{path}: declare exactly one canonical package workflow job" unless package_jobs.one?

status_jobs = jobs.each_with_object([]) do |(name, job), matches|
  matches << name if job.is_a?(Hash) && job["name"] == "CI status"
end
abort "#{path}: declare exactly one job named CI status" unless status_jobs.one?

status = jobs.fetch(status_jobs.first)
needs = status["needs"]
needs = [needs] if needs.is_a?(String)
abort "#{path}: CI status must need the canonical package job" unless needs.is_a?(Array) && needs.include?(package_jobs.first)
