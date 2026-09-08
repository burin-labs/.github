# frozen_string_literal: true

require "json"
require "open3"
require "tempfile"
require "time"
require "tmpdir"
require "uri"

module CiRuntimeEvidence
  SCHEMA_VERSION = 1
  MAX_CONCURRENCY = 8
  MAX_QUERY_COUNT = 100
  API_VERSION = "2026-03-10"

  class InvalidEvidence < StandardError; end

  class GhClient
    def json(endpoint)
      stdout, stderr, status = Open3.capture3(
        "gh", "api", "-H", "X-GitHub-Api-Version: #{API_VERSION}", endpoint
      )
      raise InvalidEvidence, "GitHub API read failed: #{compact(stderr)}" unless status.success?

      JSON.parse(stdout)
    rescue JSON::ParserError => error
      raise InvalidEvidence, "GitHub API returned invalid JSON: #{error.message}"
    end

    def run_logs(repository, run_id, job_names)
      stdout, stderr, status = Open3.capture3(
        "gh", "api", "-H", "X-GitHub-Api-Version: #{API_VERSION}",
        "/repos/#{repository}/actions/runs/#{run_id}/logs"
      )
      raise InvalidEvidence, "run #{run_id} log read failed: #{compact(stderr)}" unless status.success?

      Tempfile.create(["ci-runtime-evidence-#{run_id}", ".zip"]) do |archive|
        archive.binmode
        archive.write(stdout)
        archive.flush
        extract_run_logs(archive.path, run_id, job_names)
      end
    end

    private

    def compact(text)
      value = text.to_s.lines.last(3).join(" ").strip
      value.empty? ? "no diagnostic" : value
    end

    def extract_run_logs(archive_path, run_id, job_names)
      listing, listing_stderr, listing_status = Open3.capture3("unzip", "-Z1", archive_path)
      unless listing_status.success?
        raise InvalidEvidence, "run #{run_id} log index failed: #{compact(listing_stderr)}"
      end
      entries = listing.lines.map(&:chomp)
      unsafe = entries.find do |entry|
        entry.empty? || entry.start_with?("/") || entry.split("/").include?("..")
      end
      raise InvalidEvidence, "run #{run_id} log archive contains an unsafe path" if unsafe

      Dir.mktmpdir("ci-runtime-evidence-#{run_id}") do |directory|
        _output, unzip_stderr, unzip_status = Open3.capture3("unzip", "-qq", archive_path, "-d", directory)
        unless unzip_status.success?
          raise InvalidEvidence, "run #{run_id} log extraction failed: #{compact(unzip_stderr)}"
        end
        logs = job_names.to_h { |name| [name, +""] }
        archive_names = {}
        job_names.each do |name|
          archive_name = name.gsub(" / ", " _ ")
          if archive_names.key?(archive_name)
            raise InvalidEvidence, "run #{run_id} job names collapse to the same log archive name"
          end
          archive_names[archive_name] = name
        end
        Dir.glob(File.join(directory, "**", "*"), File::FNM_DOTMATCH).sort.each do |path|
          next if File.directory?(path)
          raise InvalidEvidence, "run #{run_id} log archive contains a link" if File.symlink?(path)
          next unless File.file?(path)

          relative = path.delete_prefix("#{directory}/")
          match = relative.match(/\A\d+_(.*)\.txt\z/)
          job = match ? archive_names[match[1]] : nil
          next unless job

          logs[job] = File.read(path, invalid: :replace, undef: :replace)
        end
        logs
      end
    end
  end

  module_function

  def parse_queries(raw)
    queries = JSON.parse(raw)
    raise InvalidEvidence, "queries-json must be a non-empty JSON list" unless queries.is_a?(Array) && queries.any?

    queries.map.with_index do |query, index|
      raise InvalidEvidence, "query #{index + 1} must be an object" unless query.is_a?(Hash)

      event = required_text(query["event"], "query #{index + 1} event")
      count = query["count"]
      unless count.is_a?(Integer) && count.between?(1, MAX_QUERY_COUNT)
        raise InvalidEvidence, "query #{index + 1} count must be an integer from 1 to #{MAX_QUERY_COUNT}"
      end
      branch = query["branch"]
      if branch && (!branch.is_a?(String) || branch.strip.empty?)
        raise InvalidEvidence, "query #{index + 1} branch must be a non-empty string"
      end
      {"event" => event, "count" => count, "branch" => branch}
    end
  rescue JSON::ParserError => error
    raise InvalidEvidence, "queries-json is invalid JSON: #{error.message}"
  end

  def collect(repository:, workflow:, queries:, client: GhClient.new, generated_at: Time.now.utc.iso8601)
    repository = required_text(repository, "repository")
    workflow = required_text(workflow, "workflow")
    selected = queries.flat_map do |query|
      runs_for_query(client, repository, workflow, query)
    end
    ids = selected.map { |entry| entry.fetch("run").fetch("id") }
    if ids.uniq.length != ids.length
      raise InvalidEvidence, "run queries overlap: measured #{ids.length} rows but only #{ids.uniq.length} unique ids"
    end

    details = parallel_map(selected, MAX_CONCURRENCY) do |entry|
      normalize_run(client, repository, entry.fetch("query"), entry.fetch("run"))
    end
    ordered = details.sort_by { |run| [Time.iso8601(run.fetch("createdAt")), run.fetch("id")] }.reverse
    expected = queries.sum { |query| query.fetch("count") }
    unless ordered.length == expected
      raise InvalidEvidence, "runtime census measured #{ordered.length} of #{expected} requested runs"
    end

    {
      "schemaVersion" => SCHEMA_VERSION,
      "generatedAt" => generated_at,
      "repository" => repository,
      "workflow" => workflow,
      "requestedRuns" => expected,
      "measuredRuns" => ordered.length,
      "queries" => queries,
      "runs" => ordered
    }
  end

  def runs_for_query(client, repository, workflow, query)
    parameters = {
      "event" => query.fetch("event"),
      "status" => "completed",
      "per_page" => MAX_QUERY_COUNT.to_s
    }
    parameters["branch"] = query.fetch("branch") if query["branch"]
    endpoint = "/repos/#{repository}/actions/workflows/#{workflow}/runs?#{URI.encode_www_form(parameters)}"
    response = client.json(endpoint)
    runs = response["workflow_runs"]
    raise InvalidEvidence, "#{query_label(query)} response omitted workflow_runs" unless runs.is_a?(Array)

    count = query.fetch("count")
    if runs.length < count
      raise InvalidEvidence, "#{query_label(query)} measured #{runs.length} of #{count} requested runs"
    end
    runs.first(count).map do |run|
      raise InvalidEvidence, "#{query_label(query)} contains a non-object run" unless run.is_a?(Hash)

      {"query" => query, "run" => run}
    end
  end

  def normalize_run(client, repository, query, raw)
    run_id = positive_integer(raw["id"], "run id")
    created_at = timestamp(raw["created_at"], "run #{run_id} created_at")
    updated_at = timestamp(raw["updated_at"], "run #{run_id} updated_at")
    raise InvalidEvidence, "run #{run_id} updated_at precedes created_at" if updated_at < created_at

    jobs = all_jobs(client, repository, run_id).map { |job| normalize_job(run_id, job) }
    cache = if jobs.empty?
      []
    else
      job_names = jobs.map { |job| job.fetch("name") }
      parse_cache_observations(client.run_logs(repository, run_id, job_names), run_id, job_names)
    end
    {
      "id" => run_id,
      "event" => query.fetch("event"),
      "branch" => raw["head_branch"],
      "conclusion" => required_text(raw["conclusion"], "run #{run_id} conclusion"),
      "createdAt" => created_at.iso8601,
      "wallMs" => milliseconds(updated_at - created_at),
      "url" => required_text(raw["html_url"], "run #{run_id} html_url"),
      "jobs" => jobs,
      "cache" => cache
    }
  end

  def all_jobs(client, repository, run_id)
    jobs = []
    page = 1
    total = nil
    loop do
      endpoint = "/repos/#{repository}/actions/runs/#{run_id}/jobs?per_page=100&page=#{page}"
      response = client.json(endpoint)
      rows = response["jobs"]
      count = response["total_count"]
      raise InvalidEvidence, "run #{run_id} jobs page #{page} omitted jobs" unless rows.is_a?(Array)
      unless count.is_a?(Integer) && count >= 0
        raise InvalidEvidence, "run #{run_id} jobs page #{page} omitted total_count"
      end
      total ||= count
      if count != total
        raise InvalidEvidence, "run #{run_id} job total changed from #{total} to #{count} during pagination"
      end
      jobs.concat(rows)
      break if jobs.length >= total
      raise InvalidEvidence, "run #{run_id} jobs page #{page} was empty before #{total} rows" if rows.empty?

      page += 1
    end
    if jobs.length != total
      raise InvalidEvidence, "run #{run_id} measured #{jobs.length} of #{total} reported jobs"
    end
    ids = jobs.map { |job| job.is_a?(Hash) ? job["id"] : nil }
    unless ids.none?(&:nil?) && ids.uniq.length == ids.length
      raise InvalidEvidence, "run #{run_id} jobs require unique ids"
    end
    jobs
  end

  def normalize_job(run_id, raw)
    raise InvalidEvidence, "run #{run_id} contains a non-object job" unless raw.is_a?(Hash)

    id = positive_integer(raw["id"], "run #{run_id} job id")
    name = required_text(raw["name"], "job #{id} name")
    created_at = optional_timestamp(raw["created_at"], "job #{id} created_at")
    started_at = optional_timestamp(raw["started_at"], "job #{id} started_at")
    completed_at = optional_timestamp(raw["completed_at"], "job #{id} completed_at")
    if raw["conclusion"] == "skipped"
      started_at = nil
      completed_at = nil
    end
    if started_at && completed_at && completed_at < started_at
      raise InvalidEvidence, "job #{id} completed_at precedes started_at"
    end
    if created_at && started_at && started_at < created_at
      raise InvalidEvidence, "job #{id} started_at precedes created_at"
    end
    {
      "id" => id,
      "name" => name,
      "conclusion" => raw["conclusion"],
      "wallMs" => started_at && completed_at ? milliseconds(completed_at - started_at) : nil,
      "queueMs" => created_at && started_at ? milliseconds(started_at - created_at) : nil,
      "runnerClass" => runner_class(raw),
      "steps" => normalize_steps(id, raw["steps"])
    }
  end

  def normalize_steps(job_id, raw_steps)
    raise InvalidEvidence, "job #{job_id} omitted steps" unless raw_steps.is_a?(Array)

    raw_steps.map do |raw|
      raise InvalidEvidence, "job #{job_id} contains a non-object step" unless raw.is_a?(Hash)

      started_at = optional_timestamp(raw["started_at"], "job #{job_id} step started_at")
      completed_at = optional_timestamp(raw["completed_at"], "job #{job_id} step completed_at")
      if raw["conclusion"] == "skipped"
        started_at = nil
        completed_at = nil
      end
      if started_at && completed_at && completed_at < started_at
        raise InvalidEvidence, "job #{job_id} step completed_at precedes started_at"
      end
      {
        "name" => required_text(raw["name"], "job #{job_id} step name"),
        "conclusion" => raw["conclusion"],
        "wallMs" => started_at && completed_at ? milliseconds(completed_at - started_at) : nil
      }
    end
  end

  def runner_class(raw)
    labels = raw["labels"].is_a?(Array) ? raw["labels"].map(&:to_s) : []
    runner_name = raw["runner_name"].to_s
    if runner_name.start_with?("blacksmith-") || labels.any? { |label| label.start_with?("blacksmith-") }
      "blacksmith"
    elsif labels.include?("self-hosted")
      "self-hosted"
    elsif runner_name.start_with?("GitHub Actions ") || labels.any? { |label| label.end_with?("-latest") }
      "github-hosted"
    elsif runner_name.empty? && labels.empty?
      "unassigned"
    else
      "other"
    end
  end

  def parse_cache_observations(logs, run_id, job_names)
    observations = {}
    job_names.each do |job|
      logs.fetch(job, "").each_line do |message|
        message = message.strip
        if (match = message.match(/Cache restored from key:\s*(\S+)/i)) ||
            (match = message.match(/Cache hit for:\s*(\S+)/i))
          add_cache_observation(observations, job, match[1], "hit")
        elsif (match = message.match(/Cache not found for input keys:\s*(.*)\z/i))
          key = match[1].to_s.strip.split(/[ ,]/).find { |part| !part.empty? } || "unreported-key"
          add_cache_observation(observations, job, key, "miss")
        end
      end
    end
    observations.values.sort_by { |row| [row.fetch("job"), row.fetch("key"), row.fetch("outcome")] }
  end

  def add_cache_observation(observations, job, key, outcome)
    normalized = key.sub(/[,:]\z/, "")
    identity = [job, normalized]
    existing = observations[identity]
    if existing && existing.fetch("outcome") != outcome
      raise InvalidEvidence, "cache #{normalized} in #{job} reported both hit and miss"
    end
    observations[identity] ||= {
      "job" => job,
      "key" => normalized,
      "outcome" => outcome,
      "source" => "github-actions-log"
    }
  end

  def parallel_map(items, limit, &block)
    queue = Queue.new
    items.each_with_index { |item, index| queue << [index, item] }
    results = Array.new(items.length)
    errors = Queue.new
    workers = [limit, items.length].min.times.map do
      Thread.new do
        loop do
          index, item = queue.pop(true)
          results[index] = block.call(item)
        rescue ThreadError
          break
        rescue StandardError => error
          errors << error
          break
        end
      end
    end
    workers.each(&:join)
    raise errors.pop unless errors.empty?
    raise InvalidEvidence, "parallel census stopped before every run was measured" if results.any?(&:nil?)

    results
  end

  def required_text(value, field)
    raise InvalidEvidence, "#{field} must be a non-empty string" unless value.is_a?(String) && !value.strip.empty?

    value
  end

  def positive_integer(value, field)
    raise InvalidEvidence, "#{field} must be a positive integer" unless value.is_a?(Integer) && value.positive?

    value
  end

  def timestamp(value, field)
    Time.iso8601(required_text(value, field))
  rescue ArgumentError
    raise InvalidEvidence, "#{field} must be an ISO-8601 timestamp"
  end

  def optional_timestamp(value, field)
    return nil if value.nil?

    timestamp(value, field)
  end

  def milliseconds(seconds)
    (seconds * 1000).round
  end

  def query_label(query)
    branch = query["branch"] ? " branch=#{query.fetch('branch')}" : ""
    "event=#{query.fetch('event')}#{branch}"
  end

  def cli(env = ENV)
    queries = parse_queries(required_text(env["CI_RUNTIME_QUERIES_JSON"], "CI_RUNTIME_QUERIES_JSON"))
    report = collect(
      repository: env["CI_RUNTIME_REPOSITORY"],
      workflow: env["CI_RUNTIME_WORKFLOW"],
      queries: queries
    )
    output = required_text(env["CI_RUNTIME_OUTPUT"], "CI_RUNTIME_OUTPUT")
    File.write(output, JSON.pretty_generate(report) + "\n")
    puts "Measured #{report.fetch('measuredRuns')} workflow runs into #{output}"
    0
  rescue InvalidEvidence => error
    warn "ci-runtime-evidence: #{error.message}"
    1
  end
end

exit CiRuntimeEvidence.cli if $PROGRAM_NAME == __FILE__
