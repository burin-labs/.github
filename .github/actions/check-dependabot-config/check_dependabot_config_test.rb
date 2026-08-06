# frozen_string_literal: true

# Covers check_dependabot_config.rb — four silent Dependabot delivery failures.
# Each case builds a throwaway repo and runs the real script against it.

require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"

class CheckDependabotConfigTest < Minitest::Test
  CHECKER = File.expand_path("check_dependabot_config.rb", __dir__)

  # Indentation is load-bearing: these fragments are spliced under an update entry.
  CATCH_ALL = <<~YAML.gsub(/^/, "    ")
    groups:
      everything:
        patterns:
          - "*"
  YAML

  INLINE_CATCH_ALL = <<~YAML.gsub(/^/, "    ")
    groups:
      everything:
        patterns: ["*"]
  YAML

  BASE_FILES = {
    "pnpm-lock.yaml" => "lockfileVersion: '9.0'\n",
    "pnpm-workspace.yaml" => "packages: []\n\noverrides:\n  left-pad: \"^1.3.0\"\n",
  }.freeze

  NPM_ENTRY = <<~YAML.gsub(/^/, "  ").sub(/\n\z/, "\n#{CATCH_ALL}")
    - package-ecosystem: "npm"
      directory: "/"
      schedule:
        interval: "weekly"
  YAML

  def run_check(config:, cargo: [], files: {}, bare: false, env: {})
    Dir.mktmpdir("dependabot-config-") do |fixture_root|
      FileUtils.mkdir_p(File.join(fixture_root, ".github"))
      File.write(File.join(fixture_root, ".github", "dependabot.yml"), config)

      cargo.each do |manifest|
        dir = File.join(fixture_root, manifest.fetch(:dir))
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "Cargo.toml"), manifest.fetch(:body))
      end

      merged = bare ? files : BASE_FILES.merge(files)
      merged.each do |relative, body|
        full = File.join(fixture_root, relative)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, body)
      end

      stdout, stderr, status = Open3.capture3(
        {
          "DEPENDABOT_CHECK_ROOT" => fixture_root,
          "DEPENDABOT_CHECK_REQUIRE_LOCKFILES" => "0",
          "DEPENDABOT_CHECK_REQUIRE_OVERRIDES" => "0",
        }.merge(env),
        "ruby",
        CHECKER,
      )
      { status: status.exitstatus, output: "#{stdout}#{stderr}" }
    end
  end

  def cargo_config(directory: "/crates/tui", catch_all: CATCH_ALL)
    <<~YAML
      version: 2
      updates:
        - package-ecosystem: "cargo"
          directory: "#{directory}"
          schedule:
            interval: "weekly"
    YAML
      .sub(/\n\z/, "\n#{catch_all}#{NPM_ENTRY}")
  end

  CONTAINED = [
    { dir: "crates/tui", body: "[workspace]\nmembers = [\n    \"util\",\n    \"flags\",\n]\n" },
    { dir: "crates/tui/util", body: "[package]\nname = \"util\"\n" },
    { dir: "crates/tui/flags", body: "[package]\nname = \"flags\"\n" },
  ].freeze

  # ---- invariant 1: cargo scope

  def test_accepts_contained_cargo_workspace
    result = run_check(config: cargo_config, cargo: CONTAINED)
    assert_equal 0, result[:status], result[:output]
    assert_match(/Dependabot config OK/, result[:output])
  end

  def test_rejects_workspace_member_outside_directory
    cargo = [
      { dir: "crates/tui", body: "[workspace]\nmembers = [\n    \"util\",\n    \"../shared\",\n]\n" },
      { dir: "crates/tui/util", body: "[package]\nname = \"util\"\n" },
      { dir: "crates/shared", body: "[package]\nname = \"shared\"\n" },
    ]
    result = run_check(config: cargo_config, cargo: cargo)
    assert_equal 1, result[:status], result[:output]
    assert_match(/members.*outside/, result[:output])
  end

  def test_rejects_path_dependency_outside_directory
    cargo = [
      { dir: "crates/tui", body: "[workspace]\nmembers = [\"util\"]\n" },
      {
        dir: "crates/tui/util",
        body: "[package]\nname = \"util\"\n\n[dependencies]\nshared = { path = \"../../shared\" }\n",
      },
      { dir: "crates/shared", body: "[package]\nname = \"shared\"\n" },
    ]
    result = run_check(config: cargo_config, cargo: cargo)
    assert_equal 1, result[:status], result[:output]
    assert_match(/path dependency.*outside/, result[:output])
  end

  def test_rejects_cargo_directory_without_manifest
    result = run_check(config: cargo_config(directory: "/missing"), cargo: [])
    assert_equal 1, result[:status], result[:output]
    assert_match(/has no Cargo\.toml/, result[:output])
  end

  # ---- invariant 2: lockfile coverage

  def test_rejects_uncovered_lockfile
    result = run_check(
      config: <<~YAML,
        version: 2
        updates:
          - package-ecosystem: "github-actions"
            directory: "/"
            schedule:
              interval: "weekly"
        #{CATCH_ALL}
      YAML
      bare: true,
      files: { "site/pnpm-lock.yaml" => "lockfileVersion: '9.0'\n" },
    )
    assert_equal 1, result[:status], result[:output]
    assert_match(%r{site/pnpm-lock\.yaml}, result[:output])
    assert_match(/no .* entry names/, result[:output])
  end

  def test_accepts_actions_only_repo_without_lockfiles
    result = run_check(
      config: <<~YAML,
        version: 2
        updates:
          - package-ecosystem: "github-actions"
            directory: "/"
            schedule:
              interval: "weekly"
        #{CATCH_ALL}
      YAML
      bare: true,
    )
    assert_equal 0, result[:status], result[:output]
  end

  def test_skips_fixture_lockfiles
    result = run_check(
      config: <<~YAML,
        version: 2
        updates:
          - package-ecosystem: "github-actions"
            directory: "/"
            schedule:
              interval: "weekly"
        #{CATCH_ALL}
      YAML
      bare: true,
      files: { "fixtures/sample/pnpm-lock.yaml" => "lockfileVersion: '9.0'\n" },
    )
    assert_equal 0, result[:status], result[:output]
  end

  # ---- invariant 3: catch-all

  def test_rejects_missing_catch_all
    result = run_check(
      config: <<~YAML,
        version: 2
        updates:
          - package-ecosystem: "npm"
            directory: "/"
            schedule:
              interval: "weekly"
      YAML
      bare: true,
      files: { "pnpm-lock.yaml" => "lockfileVersion: '9.0'\n" },
    )
    assert_equal 1, result[:status], result[:output]
    assert_match(/no catch-all group/, result[:output])
  end

  def test_accepts_inline_catch_all_patterns
    # harn-cloud shape (burin-code#5951) — must not false-fail.
    result = run_check(
      config: <<~YAML,
        version: 2
        updates:
          - package-ecosystem: "npm"
            directory: "/"
            schedule:
              interval: "weekly"
        #{INLINE_CATCH_ALL}
      YAML
      bare: true,
      files: { "pnpm-lock.yaml" => "lockfileVersion: '9.0'\n" },
    )
    assert_equal 0, result[:status], result[:output]
  end

  def test_rejects_star_only_under_exclude_patterns
    result = run_check(
      config: <<~YAML,
        version: 2
        updates:
          - package-ecosystem: "npm"
            directory: "/"
            schedule:
              interval: "weekly"
            groups:
              named:
                patterns: ["left-pad"]
                exclude-patterns: ["*"]
      YAML
      bare: true,
      files: { "pnpm-lock.yaml" => "lockfileVersion: '9.0'\n" },
    )
    assert_equal 1, result[:status], result[:output]
    assert_match(/no catch-all group/, result[:output])
  end

  def test_rejects_scalar_star_as_catch_all
    result = run_check(
      config: <<~YAML,
        version: 2
        updates:
          - package-ecosystem: "npm"
            directory: "/"
            schedule:
              interval: "weekly"
            groups:
              named:
                dependency-type: "*"
      YAML
      bare: true,
      files: { "pnpm-lock.yaml" => "lockfileVersion: '9.0'\n" },
    )
    assert_equal 1, result[:status], result[:output]
    assert_match(/no catch-all group/, result[:output])
  end

  def test_rejects_default_members_outside_directory
    cargo = [
      {
        dir: "crates/tui",
        body: "[workspace]\nmembers = [\"util\"]\ndefault-members = [\"../shared\"]\n",
      },
      { dir: "crates/tui/util", body: "[package]\nname = \"util\"\n" },
      { dir: "crates/shared", body: "[package]\nname = \"shared\"\n" },
    ]
    result = run_check(config: cargo_config, cargo: cargo)
    assert_equal 1, result[:status], result[:output]
    assert_match(/default-members.*outside/, result[:output])
  end

  def test_accepts_directories_plural
    result = run_check(
      config: <<~YAML,
        version: 2
        updates:
          - package-ecosystem: "npm"
            directories:
              - "/a"
              - "/b"
            schedule:
              interval: "weekly"
        #{CATCH_ALL}
      YAML
      bare: true,
      files: {
        "a/pnpm-lock.yaml" => "lockfileVersion: '9.0'\n",
        "b/pnpm-lock.yaml" => "lockfileVersion: '9.0'\n",
      },
    )
    assert_equal 0, result[:status], result[:output]
  end

  # ---- invariant 4: override ceilings

  def test_rejects_exact_override_without_pin_annotation
    result = run_check(
      config: <<~YAML,
        version: 2
        updates:
          - package-ecosystem: "npm"
            directory: "/"
            schedule:
              interval: "weekly"
        #{CATCH_ALL}
      YAML
      bare: true,
      files: {
        "pnpm-lock.yaml" => "lockfileVersion: '9.0'\n",
        "pnpm-workspace.yaml" => "packages: []\n\noverrides:\n  left-pad: \"1.3.0\"\n",
      },
    )
    assert_equal 1, result[:status], result[:output]
    assert_match(/exact version/, result[:output])
  end

  def test_accepts_exact_override_with_pin_annotation
    result = run_check(
      config: <<~YAML,
        version: 2
        updates:
          - package-ecosystem: "npm"
            directory: "/"
            schedule:
              interval: "weekly"
        #{CATCH_ALL}
      YAML
      bare: true,
      files: {
        "pnpm-lock.yaml" => "lockfileVersion: '9.0'\n",
        "pnpm-workspace.yaml" => "packages: []\n\noverrides:\n  left-pad: \"1.3.0\" # pin: deliberate ceiling\n",
      },
    )
    assert_equal 0, result[:status], result[:output]
  end

  # ---- anti-vacuity parameterization

  def test_require_lockfiles_fails_when_none_present
    result = run_check(
      config: <<~YAML,
        version: 2
        updates:
          - package-ecosystem: "github-actions"
            directory: "/"
            schedule:
              interval: "weekly"
        #{CATCH_ALL}
      YAML
      bare: true,
      env: { "DEPENDABOT_CHECK_REQUIRE_LOCKFILES" => "1" },
    )
    assert_equal 1, result[:status], result[:output]
    assert_match(/ZERO committed lockfiles/, result[:output])
  end

  def test_passes_this_org_repo_config
    root = File.expand_path("../../..", __dir__)
    stdout, stderr, status = Open3.capture3(
      {
        "DEPENDABOT_CHECK_ROOT" => root,
        "DEPENDABOT_CHECK_REQUIRE_LOCKFILES" => "0",
        "DEPENDABOT_CHECK_REQUIRE_OVERRIDES" => "0",
      },
      "ruby",
      CHECKER,
    )
    assert status.success?, "#{stdout}#{stderr}"
  end
end
