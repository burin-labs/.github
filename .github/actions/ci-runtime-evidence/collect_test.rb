# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "tmpdir"
require "yaml"
require_relative "collect"

class CiRuntimeEvidenceTest < Minitest::Test
  class FakeClient
    attr_reader :json_calls, :log_calls

    def initialize(json:, logs: {})
      @json = json
      @logs = logs
      @json_calls = []
      @log_calls = []
    end

    def json(endpoint)
      @json_calls << endpoint
      Marshal.load(Marshal.dump(@json.fetch(endpoint)))
    end

    def run_logs(repository, run_id, _job_names)
      @log_calls << [repository, run_id]
      @logs.fetch(run_id)
    end
  end

  def query(event:, count:, branch: nil)
    {"event" => event, "count" => count, "branch" => branch}
  end

  def workflow_run(id:, event:, branch:)
    {
      "id" => id,
      "event" => event,
      "head_branch" => branch,
      "conclusion" => "success",
      "created_at" => "2026-09-08T10:00:00Z",
      "updated_at" => "2026-09-08T10:02:00Z",
      "html_url" => "https://example.test/runs/#{id}"
    }
  end

  def job(id:, name:, labels: ["ubuntu-latest"], runner_name: "GitHub Actions 1")
    {
      "id" => id,
      "name" => name,
      "conclusion" => "success",
      "created_at" => "2026-09-08T10:00:05Z",
      "started_at" => "2026-09-08T10:00:08Z",
      "completed_at" => "2026-09-08T10:01:08Z",
      "runner_name" => runner_name,
      "labels" => labels,
      "steps" => [{
        "name" => "Restore cache",
        "conclusion" => "success",
        "started_at" => "2026-09-08T10:00:10Z",
        "completed_at" => "2026-09-08T10:00:14Z"
      }]
    }
  end

  def endpoints
    {
      "/repos/acme/widgets/actions/workflows/ci.yml/runs?event=pull_request&status=completed&per_page=100" => {
        "workflow_runs" => [workflow_run(id: 10, event: "pull_request", branch: "feature")]
      },
      "/repos/acme/widgets/actions/workflows/ci.yml/runs?event=push&status=completed&per_page=100&branch=main" => {
        "workflow_runs" => [workflow_run(id: 20, event: "push", branch: "main")]
      },
      "/repos/acme/widgets/actions/runs/10/jobs?per_page=100&page=1" => {
        "total_count" => 1,
        "jobs" => [job(id: 101, name: "test")]
      },
      "/repos/acme/widgets/actions/runs/20/jobs?per_page=100&page=1" => {
        "total_count" => 1,
        "jobs" => [job(id: 201, name: "build", labels: ["self-hosted"], runner_name: "worker-1")]
      }
    }
  end

  def test_collects_non_zero_queue_runner_and_cache_controls
    pull_log = <<~LOG
      test\tUNKNOWN STEP\t2026-09-08T10:00:11Z Cache hit for: node-cache-Linux-key
      test\tUNKNOWN STEP\t2026-09-08T10:00:12Z Cache restored from key: node-cache-Linux-key
    LOG
    push_log = <<~LOG
      build\tUNKNOWN STEP\t2026-09-08T10:00:11Z Cache not found for input keys: rust-target-key
    LOG
    client = FakeClient.new(json: endpoints, logs: {10 => {"test" => pull_log}, 20 => {"build" => push_log}})
    report = CiRuntimeEvidence.collect(
      repository: "acme/widgets",
      workflow: "ci.yml",
      queries: [query(event: "pull_request", count: 1), query(event: "push", count: 1, branch: "main")],
      client: client,
      generated_at: "2026-09-08T11:00:00Z"
    )

    assert_equal 2, report.fetch("requestedRuns")
    assert_equal 2, report.fetch("measuredRuns")
    by_id = report.fetch("runs").to_h { |run| [run.fetch("id"), run] }
    assert_equal 3000, by_id.fetch(10).dig("jobs", 0, "queueMs")
    assert_equal "github-hosted", by_id.fetch(10).dig("jobs", 0, "runnerClass")
    assert_equal "self-hosted", by_id.fetch(20).dig("jobs", 0, "runnerClass")
    assert_equal [{
      "job" => "test",
      "key" => "node-cache-Linux-key",
      "outcome" => "hit",
      "source" => "github-actions-log"
    }], by_id.fetch(10).fetch("cache")
    assert_equal "miss", by_id.fetch(20).dig("cache", 0, "outcome")
  end

  def test_short_run_page_fails_instead_of_reporting_zero
    data = endpoints
    data.fetch("/repos/acme/widgets/actions/workflows/ci.yml/runs?event=pull_request&status=completed&per_page=100")["workflow_runs"] = []
    client = FakeClient.new(json: data)
    error = assert_raises(CiRuntimeEvidence::InvalidEvidence) do
      CiRuntimeEvidence.collect(
        repository: "acme/widgets",
        workflow: "ci.yml",
        queries: [query(event: "pull_request", count: 1)],
        client: client
      )
    end
    assert_includes error.message, "measured 0 of 1 requested runs"
  end

  def test_partial_job_pagination_fails
    data = endpoints
    data.fetch("/repos/acme/widgets/actions/runs/10/jobs?per_page=100&page=1")["total_count"] = 2
    data["/repos/acme/widgets/actions/runs/10/jobs?per_page=100&page=2"] = {
      "total_count" => 2,
      "jobs" => []
    }
    client = FakeClient.new(json: data, logs: {10 => {}})
    error = assert_raises(CiRuntimeEvidence::InvalidEvidence) do
      CiRuntimeEvidence.collect(
        repository: "acme/widgets",
        workflow: "ci.yml",
        queries: [query(event: "pull_request", count: 1)],
        client: client
      )
    end
    assert_includes error.message, "empty before 2 rows"
  end

  def test_paginates_every_reported_job
    data = endpoints
    first = data.fetch("/repos/acme/widgets/actions/runs/10/jobs?per_page=100&page=1")
    first["total_count"] = 2
    data["/repos/acme/widgets/actions/runs/10/jobs?per_page=100&page=2"] = {
      "total_count" => 2,
      "jobs" => [job(id: 102, name: "package")]
    }
    client = FakeClient.new(json: data, logs: {10 => {}})

    report = CiRuntimeEvidence.collect(
      repository: "acme/widgets",
      workflow: "ci.yml",
      queries: [query(event: "pull_request", count: 1)],
      client: client
    )

    assert_equal %w[test package], report.dig("runs", 0, "jobs").map { |row| row.fetch("name") }
    assert_includes client.json_calls, "/repos/acme/widgets/actions/runs/10/jobs?per_page=100&page=2"
  end

  def test_zero_jobs_is_a_measured_empty_result
    data = endpoints
    data["/repos/acme/widgets/actions/runs/10/jobs?per_page=100&page=1"] = {
      "total_count" => 0,
      "jobs" => []
    }
    client = FakeClient.new(json: data)

    report = CiRuntimeEvidence.collect(
      repository: "acme/widgets",
      workflow: "ci.yml",
      queries: [query(event: "pull_request", count: 1)],
      client: client
    )

    assert_empty report.dig("runs", 0, "jobs")
    assert_empty report.dig("runs", 0, "cache")
    assert_empty client.log_calls
  end

  def test_overlapping_queries_fail_instead_of_double_counting
    client = FakeClient.new(json: endpoints)
    error = assert_raises(CiRuntimeEvidence::InvalidEvidence) do
      CiRuntimeEvidence.collect(
        repository: "acme/widgets",
        workflow: "ci.yml",
        queries: [query(event: "pull_request", count: 1), query(event: "pull_request", count: 1)],
        client: client
      )
    end

    assert_includes error.message, "only 1 unique ids"
    assert_empty client.log_calls
  end

  def test_duplicate_job_ids_fail
    data = endpoints
    data["/repos/acme/widgets/actions/runs/10/jobs?per_page=100&page=1"] = {
      "total_count" => 2,
      "jobs" => [job(id: 101, name: "test"), job(id: 101, name: "package")]
    }
    client = FakeClient.new(json: data)

    error = assert_raises(CiRuntimeEvidence::InvalidEvidence) do
      CiRuntimeEvidence.collect(
        repository: "acme/widgets",
        workflow: "ci.yml",
        queries: [query(event: "pull_request", count: 1)],
        client: client
      )
    end

    assert_includes error.message, "jobs require unique ids"
  end

  def test_malformed_timestamps_fail
    data = endpoints
    data.fetch("/repos/acme/widgets/actions/workflows/ci.yml/runs?event=pull_request&status=completed&per_page=100")
      .fetch("workflow_runs").fetch(0)["created_at"] = "yesterday"
    client = FakeClient.new(json: data)

    error = assert_raises(CiRuntimeEvidence::InvalidEvidence) do
      CiRuntimeEvidence.collect(
        repository: "acme/widgets",
        workflow: "ci.yml",
        queries: [query(event: "pull_request", count: 1)],
        client: client
      )
    end

    assert_includes error.message, "must be an ISO-8601 timestamp"
  end

  def test_skipped_jobs_ignore_githubs_inverted_execution_timestamps
    data = endpoints
    skipped = job(id: 101, name: "conditional")
    skipped["conclusion"] = "skipped"
    skipped["started_at"] = "2026-09-08T10:00:08Z"
    skipped["completed_at"] = "2026-09-08T10:00:07Z"
    data.fetch("/repos/acme/widgets/actions/runs/10/jobs?per_page=100&page=1")["jobs"] = [skipped]
    client = FakeClient.new(json: data, logs: {10 => {}})

    report = CiRuntimeEvidence.collect(
      repository: "acme/widgets",
      workflow: "ci.yml",
      queries: [query(event: "pull_request", count: 1)],
      client: client
    )

    assert_nil report.dig("runs", 0, "jobs", 0, "wallMs")
    assert_nil report.dig("runs", 0, "jobs", 0, "queueMs")
  end

  def test_inverted_executed_job_timestamps_fail
    data = endpoints
    executed = data.fetch("/repos/acme/widgets/actions/runs/10/jobs?per_page=100&page=1").fetch("jobs").fetch(0)
    executed["completed_at"] = "2026-09-08T10:00:07Z"
    client = FakeClient.new(json: data)

    error = assert_raises(CiRuntimeEvidence::InvalidEvidence) do
      CiRuntimeEvidence.collect(
        repository: "acme/widgets",
        workflow: "ci.yml",
        queries: [query(event: "pull_request", count: 1)],
        client: client
      )
    end

    assert_includes error.message, "completed_at precedes started_at"
  end

  def test_extracts_job_scoped_logs_from_githubs_archive_names
    Dir.mktmpdir("ci-runtime-evidence-test") do |directory|
      source = File.join(directory, "source")
      Dir.mkdir(source)
      File.write(
        File.join(source, "7_build _ linux.txt"),
        "2026-09-08T10:00:11Z Cache hit for: build-Linux-key\n"
      )
      archive = File.join(directory, "logs.zip")
      assert system("zip", "-q", archive, "7_build _ linux.txt", chdir: source)

      logs = CiRuntimeEvidence::GhClient.new.send(
        :extract_run_logs,
        archive,
        10,
        ["build / linux", "not executed"]
      )

      assert_includes logs.fetch("build / linux"), "Cache hit for: build-Linux-key"
      assert_empty logs.fetch("not executed")
    end
  end

  def test_action_passes_token_only_through_environment
    action = YAML.safe_load(File.read(File.join(__dir__, "action.yml")), aliases: true)
    step = action.fetch("runs").fetch("steps").fetch(0)
    assert_equal "${{ inputs.github-token }}", step.dig("env", "GH_TOKEN")
    refute_includes step.fetch("run"), "github-token"
    assert_equal "ruby \"${GITHUB_ACTION_PATH}/collect.rb\"", step.fetch("run").lines.fetch(2).strip
  end
end
