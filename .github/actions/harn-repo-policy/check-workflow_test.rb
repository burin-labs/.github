# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "tempfile"
require_relative "check-workflow"

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
          if: always()
          needs: [package]
          runs-on: ubuntu-latest
          steps:
            - uses: burin-labs/.github/.github/actions/require-successful-needs@#{"a" * 40}
              with:
                results-json: ${{ toJSON(needs.*.result) }}
    YAML
  end

  def check(body)
    Tempfile.create(["ci", ".yml"]) do |file|
      file.write(body)
      file.flush
      return [HarnWorkflowPolicy.check!(file.path), nil]
    rescue HarnWorkflowPolicy::Violation => error
      return [false, error]
    end
  end

  def assert_violation(body, code)
    ok, error = check(body)
    refute ok
    assert_instance_of HarnWorkflowPolicy::Violation, error
    assert_equal code, error.code
  end

  def test_accepts_the_canonical_structure
    ok, error = check(valid_workflow)
    assert ok, error&.report
  end

  def test_requires_merge_group
    assert_violation(valid_workflow.sub("  merge_group:\n", ""), "merge_group_required")
  end

  def test_requires_an_immutable_workflow_pin
    assert_violation(valid_workflow.sub("a" * 40, "main"), "canonical_package_missing")
  end

  def test_requires_the_org_wide_full_sha_shape
    assert_violation(valid_workflow.sub("a" * 40, "a" * 64), "canonical_package_missing")
  end

  def test_requires_the_status_rollup_to_need_the_package_job
    assert_violation(
      valid_workflow.sub("needs: [package]", "needs: [other]"),
      "status_needs_package",
    )
  end

  def test_requires_the_status_rollup_to_run_after_failures
    assert_violation(valid_workflow.sub("    if: always()\n", ""), "status_always")
  end

  def test_requires_the_co_versioned_status_contract
    assert_violation(
      valid_workflow.sub(
        "actions/require-successful-needs@#{"a" * 40}",
        "actions/require-successful-needs@#{"b" * 40}",
      ),
      "status_action",
    )
  end

  def test_requires_every_dependency_result
    assert_violation(
      valid_workflow.sub("${{ toJSON(needs.*.result) }}", "[]"),
      "status_results_projection",
    )
  end

  def with_strict(value)
    valid_workflow.sub(
      "    uses: burin-labs/.github/.github/workflows/harn-package.yml@#{"a" * 40}\n",
      "    uses: burin-labs/.github/.github/workflows/harn-package.yml@#{"a" * 40}\n" \
        "    with:\n" \
        "      strict: #{value}\n",
    )
  end

  def test_accepts_an_explicit_boolean_strict_requirement
    ok, error = check(with_strict("true"))
    assert ok, error&.report
  end

  def test_rejects_any_strict_value_that_is_not_boolean_true
    ["false", '"false"', '"${{ false }}"', '"${{ inputs.strict }}"'].each do |value|
      assert_violation(with_strict(value), "strict_required")
    end
  end

  def test_cli_reports_the_stable_violation_code
    Tempfile.create(["ci", ".yml"]) do |file|
      file.write(valid_workflow.sub("  merge_group:\n", ""))
      file.flush
      stdout, stderr, status = Open3.capture3("ruby", CHECKER, file.path)
      refute status.success?
      assert_empty stdout
      assert_equal(
        "#{file.path}: [merge_group_required] workflow must declare merge_group\n",
        stderr,
      )
    end
  end
end
