# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tempfile"

class CheckWorkflowTest < Minitest::Test
  CHECKER = File.expand_path("check-workflow.rb", __dir__)

  def valid_workflow
    <<~YAML
      name: CI
      "on":
        pull_request:
        merge_group:
      jobs:
        package:
          uses: burin-labs/.github/.github/workflows/harn-package.yml@#{"a" * 40}
        status:
          name: CI status
          needs: [package]
          runs-on: ubuntu-latest
    YAML
  end

  def check(body)
    Tempfile.create(["ci", ".yml"]) do |file|
      file.write(body)
      file.flush
      _stdout, stderr, status = Open3.capture3("ruby", CHECKER, file.path)
      [status.success?, stderr]
    end
  end

  def test_accepts_the_canonical_structure
    ok, error = check(valid_workflow)
    assert ok, error
  end

  def test_requires_merge_group
    ok, error = check(valid_workflow.sub("  merge_group:\n", ""))
    refute ok
    assert_includes error, "merge_group"
  end

  def test_requires_an_immutable_workflow_pin
    ok, error = check(valid_workflow.sub("a" * 40, "main"))
    refute ok
    assert_includes error, "immutable call"
  end

  def test_requires_the_status_rollup_to_need_the_package_job
    ok, error = check(valid_workflow.sub("needs: [package]", "needs: [other]"))
    refute ok
    assert_includes error, "CI status must need"
  end
end
