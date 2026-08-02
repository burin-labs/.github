# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"

class RequireSuccessfulNeedsTest < Minitest::Test
  CHECKER = File.expand_path("require-successful-needs.rb", __dir__)

  def check(value)
    Open3.capture3({"NEEDS_RESULTS_JSON" => value}, "ruby", CHECKER)
  end

  def test_accepts_every_declared_success
    stdout, stderr, status = check(JSON.generate(["success", "success"]))

    assert status.success?, stderr
    assert_equal "required CI dependencies succeeded: 2\n", stdout
    assert_empty stderr
  end

  def test_reports_every_non_success_result_deterministically
    _stdout, stderr, status = check(
      JSON.generate(["skipped", "failure", "failure", nil, {"result" => "success"}])
    )

    refute status.success?
    assert_equal(
      "::error::required CI dependencies did not succeed: " \
        "failure=2, malformed=2, skipped=1\n",
      stderr,
    )
  end

  def test_rejects_invalid_or_empty_needs_objects
    {
      "not-json" => "::error::results-json must be a valid dependency-result array\n",
      "[]" => "::error::results-json must contain at least one CI dependency result\n",
      "{}" => "::error::results-json must contain at least one CI dependency result\n",
    }.each do |value, expected_error|
      _stdout, stderr, status = check(value)
      refute status.success?, "expected #{value.inspect} to be rejected"
      assert_equal expected_error, stderr
    end
  end
end
