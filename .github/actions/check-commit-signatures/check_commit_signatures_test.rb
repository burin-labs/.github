# frozen_string_literal: true

# Covers check_commit_signatures.rb. Each case runs the real script against a
# throwaway commits payload shaped like the GitHub pulls/{n}/commits response.
#
# The payloads below are not invented. `no_user` with a good local signature is
# the exact shape that blocked burin-code#6442, and it is the case most worth
# holding still: the branch looked clean locally, so only the API view caught it.

require "json"
require "minitest/autorun"
require "open3"
require "tmpdir"

class CheckCommitSignaturesTest < Minitest::Test
  CHECKER = File.expand_path("check_commit_signatures.rb", __dir__)

  def commit(sha:, verified:, reason: "valid", email: "dev@example.com", author_email: nil, message: "do a thing")
    {
      "sha" => sha,
      "commit" => {
        "message" => message,
        "author" => { "email" => author_email || email },
        "committer" => { "email" => email },
        "verification" => { "verified" => verified, "reason" => reason },
      },
    }
  end

  def run_check(payload, pull_request: "42", write: true)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "commits.json")
      File.write(path, payload.is_a?(String) ? payload : JSON.generate(payload)) if write
      stdout, stderr, status = Open3.capture3(
        { "COMMITS_PAYLOAD" => path, "PULL_REQUEST_NUMBER" => pull_request },
        "ruby", CHECKER
      )
      [status.exitstatus, stdout, stderr]
    end
  end

  def test_all_verified_commits_pass
    code, stdout, = run_check([
      commit(sha: "a" * 40, verified: true),
      commit(sha: "b" * 40, verified: true),
    ])
    assert_equal 0, code
    assert_includes stdout, "All 2 commit(s)"
  end

  # The burin-code#6442 shape: signature is good, key is registered, and the only
  # defect is an email GitHub cannot map to an account.
  def test_no_user_reason_fails_and_names_the_identity
    code, _, stderr = run_check([
      commit(sha: "c" * 40, verified: true),
      commit(sha: "d" * 40, verified: false, reason: "no_user", email: "support@example.com"),
    ])
    assert_equal 1, code
    assert_includes stderr, "d" * 9
    assert_includes stderr, "no_user"
    assert_includes stderr, "not a verified email"
    assert_includes stderr, "committer support@example.com"
    assert_includes stderr, "1 of 2 commit(s)"
  end

  def test_unsigned_commit_fails
    code, _, stderr = run_check([commit(sha: "e" * 40, verified: false, reason: "unsigned")])
    assert_equal 1, code
    assert_includes stderr, "no signature at all"
  end

  # A rebase or a merge can leave the two identities different, and only the
  # committer's decides verification. Reporting one alone sends the fix to the
  # wrong place.
  def test_divergent_author_and_committer_are_both_reported
    code, _, stderr = run_check([
      commit(sha: "f" * 40, verified: false, reason: "bad_email",
             email: "committer@example.com", author_email: "author@example.com"),
    ])
    assert_equal 1, code
    assert_includes stderr, "committer committer@example.com"
    assert_includes stderr, "author author@example.com"
  end

  def test_unknown_reason_still_fails_without_a_hint
    code, _, stderr = run_check([commit(sha: "0" * 40, verified: false, reason: "some_new_reason")])
    assert_equal 1, code
    assert_includes stderr, "some_new_reason"
  end

  def test_missing_verification_block_fails_rather_than_passing
    code, _, stderr = run_check([{ "sha" => "1" * 40, "commit" => { "message" => "no verification key" } }])
    assert_equal 1, code
    assert_includes stderr, "missing verification payload"
  end

  # Anti-vacuity. Each of these is a way for the gate to examine nothing, and a
  # gate that reports green on nothing is the exact failure it was built to kill.
  def test_empty_commit_list_is_an_error_not_a_pass
    code, _, stderr = run_check([])
    assert_equal 2, code
    assert_includes stderr, "zero commits"
  end

  def test_absent_payload_is_an_error_not_a_pass
    code, _, stderr = run_check([], write: false)
    assert_equal 2, code
    assert_includes stderr, "never written"
  end

  def test_malformed_payload_is_an_error_not_a_pass
    code, _, stderr = run_check("{not json")
    assert_equal 2, code
    assert_includes stderr, "not valid JSON"
  end

  # A truncated read is an unread PR wearing a green hat.
  def test_commit_list_at_the_api_cap_is_an_error_not_a_pass
    payload = Array.new(250) { |i| commit(sha: i.to_s.rjust(40, "0"), verified: true) }
    code, _, stderr = run_check(payload)
    assert_equal 2, code
    assert_includes stderr, "250-commit API cap"
  end

  def test_non_array_payload_is_an_error_not_a_pass
    code, _, stderr = run_check({ "message" => "Not Found" })
    assert_equal 2, code
    assert_includes stderr, "expected an array"
  end
end
