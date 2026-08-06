#!/usr/bin/env ruby
# frozen_string_literal: true

# Dependabot effectiveness check for Burin Labs repositories.
#
# Dependabot failing is loud. Dependabot being UNABLE to act is silent, and
# every failure this file guards against is the silent kind: the only symptom
# is an absence of dependency PRs. Owned here so every product repo shares one
# YAML-parsing implementation — a line-reader that only understood one list
# style already produced a false "no catch-all" on harn-cloud (burin-code#5951).
#
# Invariants:
#   1. Cargo scope escape — workspace members / path deps stay inside `directory`
#   2. Lockfile coverage — every committed lockfile has a matching entry
#   3. Catch-all group — every entry has exactly-usable catch-all `patterns`
#   4. Frozen pnpm override ceilings — exact overrides need `# pin:` annotation
#
# Deliberately static: Ruby stdlib only (Psych). No network, no gems, no Harn.

require "pathname"
require "set"
require "yaml"

CONFIG = ".github/dependabot.yml"

LOCKFILE_ECOSYSTEMS = {
  "pnpm-lock.yaml" => "npm",
  "package-lock.json" => "npm",
  "yarn.lock" => "npm",
  "Cargo.lock" => "cargo",
  "Package.resolved" => "swift",
  "uv.lock" => "uv",
  "go.sum" => "gomod",
}.freeze

SKIP_DIRS = %w[
  .build
  .git
  .next
  .turbo
  .venv
  __pycache__
  build
  coverage
  dist
  node_modules
  out
  target
  vendor
].freeze

Entry = Struct.new(:ecosystem, :directory, :has_catch_all, :index, keyword_init: true)

def repo_root
  root = ENV.fetch("DEPENDABOT_CHECK_ROOT", Dir.pwd)
  Pathname(root).expand_path
end

def fixture_path?(relative)
  relative.split("/").any? do |segment|
    segment == "fixtures" ||
      segment == "testdata" ||
      segment == "__fixtures__" ||
      segment.end_with?("-fixtures")
  end
end

def files_named(root, names)
  out = []
  walk = lambda do |dir|
    dir.children.each do |child|
      next if child.basename.to_s.start_with?(".") && child.directory? && child.basename.to_s != ".github"
      next if SKIP_DIRS.include?(child.basename.to_s)

      if child.directory?
        walk.call(child)
      elsif names.include?(child.basename.to_s)
        out << child
      end
    end
  rescue Errno::EACCES, Errno::ENOENT
    # Skip unreadable trees.
  end
  walk.call(root)
  out
end

def inside?(root, candidate)
  candidate.expand_path.to_s.start_with?(root.expand_path.to_s + File::SEPARATOR) ||
    candidate.expand_path == root.expand_path
end

def normalize_scope(directory)
  directory.to_s.sub(%r{\A/+}, "").sub(%r{/+\z}, "")
end

def catch_all_pattern?(value)
  value.to_s.gsub(/\A["']|["']\z/, "").strip.match?(/\A\*+\z/)
end

def group_has_catch_all?(group)
  return false unless group.is_a?(Hash)

  patterns = group["patterns"]
  return false unless patterns.is_a?(Array)

  patterns.any? { |pattern| catch_all_pattern?(pattern) }
end

def entry_has_catch_all?(update)
  groups = update["groups"]
  return false unless groups.is_a?(Hash)

  groups.each_value.any? { |group| group_has_catch_all?(group) }
end

def entry_directories(update, ecosystem, index)
  single = update["directory"]
  many = update["directories"]
  if !single.nil? && !many.nil?
    raise "#{CONFIG}: updates[#{index}] (#{ecosystem}): sets both 'directory' and 'directories'"
  end
  if !many.nil?
    unless many.is_a?(Array) && many.all? { |d| d.is_a?(String) }
      raise "#{CONFIG}: updates[#{index}] (#{ecosystem}): 'directories' must be a list of strings"
    end
    return many
  end
  if single.nil?
    raise "#{CONFIG}: updates[#{index}] (#{ecosystem}): sets neither 'directory' nor 'directories'"
  end
  [single.to_s]
end

def parse_entries(text)
  document = YAML.safe_load(text, aliases: true)
  raise "#{CONFIG}: document is empty" if document.nil?
  raise "#{CONFIG}: expected a mapping at the root" unless document.is_a?(Hash)

  updates = document["updates"]
  raise "#{CONFIG}: missing 'updates' list" unless updates.is_a?(Array)

  entries = []
  updates.each_with_index do |update, index|
    raise "#{CONFIG}: updates[#{index}] is not a mapping" unless update.is_a?(Hash)

    ecosystem = update["package-ecosystem"]
    raise "#{CONFIG}: updates[#{index}] missing package-ecosystem" if ecosystem.nil? || ecosystem.to_s.empty?

    entry_directories(update, ecosystem, index).each do |directory|
      entries << Entry.new(
        ecosystem: ecosystem.to_s,
        directory: directory.to_s,
        has_catch_all: entry_has_catch_all?(update),
        index: index,
      )
    end
  end
  entries
end

def read_member_array(manifest, key)
  start = manifest.index(/^\s*#{Regexp.escape(key)}\s*=\s*\[/m)
  return [] if start.nil?

  from = manifest.index("[", start)
  return [] if from.nil?

  depth = 0
  i = from
  while i < manifest.length
    case manifest[i]
    when "[" then depth += 1
    when "]"
      depth -= 1
      break if depth.zero?
    end
    i += 1
  end
  raise "unterminated `#{key}` array; fix the reader" if depth != 0

  manifest[from..i].scan(/"([^"]+)"/).flatten
end

def exact_version?(value)
  value.to_s.strip.match?(/\Av?\d+(\.\d+)*(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?\z/)
end

def scan_overrides(file)
  lines = File.read(file).split("\n")
  findings = []
  scanned = 0
  in_block = false
  lines.each_with_index do |line, i|
    if line.match?(/\Aoverrides:\s*\z/)
      in_block = true
      next
    end
    in_block = false if in_block && line.match?(/\A[^\s#]/)
    next unless in_block

    entry = line.match(/\A\s+(?:"([^"]+)"|([^:#\s][^:]*?)):\s*(.+?)\s*\z/)
    next unless entry

    key = entry[1] || entry[2]
    value = entry[3]
    annotated = value.match?(/#\s*pin:/) || (i.positive? && lines[i - 1].match?(/#\s*pin:/))
    value = value.sub(/\s*#.*\z/, "").strip.gsub(/\A["']|["']\z/, "")
    next if value.empty?

    scanned += 1
    findings << { file: file, line: i + 1, key: key, value: value } if exact_version?(value) && !annotated
  end
  [findings, scanned]
end

def check!(root)
  config_path = root.join(CONFIG)
  raise "#{CONFIG} not found; this check cannot run vacuously" unless config_path.file?

  entries = parse_entries(config_path.read)
  if entries.empty?
    raise "found ZERO update entries in #{CONFIG} — this check would pass vacuously; fix the reader"
  end

  problems = []
  manifests_scanned = 0

  # ---- 1. Cargo scope
  cargo_entries = entries.select { |e| e.ecosystem == "cargo" }
  cargo_entries.each do |entry|
    scope = root.join(normalize_scope(entry.directory))
    root_manifest = scope.join("Cargo.toml")
    unless root_manifest.file?
      problems << "#{CONFIG}: updates[#{entry.index}]: directory \"#{entry.directory}\" has no Cargo.toml. " \
                  "Dependabot resolves no manifest there and produces zero updates."
      next
    end

    manifest = root_manifest.read
    %w[members default-members].each do |key|
      read_member_array(manifest, key).each do |member|
        resolved = (scope / member).expand_path
        next if inside?(scope, resolved)

        problems << "#{normalize_scope(entry.directory)}/Cargo.toml: `#{key}` entry \"#{member}\" resolves outside " \
                    "\"#{entry.directory}\", which Dependabot scopes this ecosystem to. Cargo cannot " \
                    "construct the workspace from the uploaded subtree, so every run fails with " \
                    "\"No Cargo.toml!\" and the directory silently receives no updates. " \
                    "Move the crate inside the scope, or rescope the Dependabot entry to a directory " \
                    "that contains it."
      end
    end

    files_named(scope, %w[Cargo.toml]).each do |file|
      manifests_scanned += 1
      text = file.read
      text.scan(/path\s*=\s*"([^"]+)"/).flatten.each do |dep|
        resolved = (file.dirname / dep).expand_path
        next if inside?(scope, resolved)

        rel = file.relative_path_from(root).to_s
        problems << "#{rel}: path dependency \"#{dep}\" resolves outside " \
                    "\"#{entry.directory}\". Dependabot uploads only that subtree, so the manifest " \
                    "cannot resolve and the ecosystem silently receives no updates."
      end
    end
  end

  # ---- 2. Lockfile coverage
  scopes_by_ecosystem = Hash.new { |h, k| h[k] = Set.new }
  entries.each do |entry|
    scopes_by_ecosystem[entry.ecosystem] << normalize_scope(entry.directory)
  end

  lockfiles_considered = 0
  files_named(root, LOCKFILE_ECOSYSTEMS.keys).each do |file|
    relative = file.relative_path_from(root).to_s
    next if fixture_path?(relative)

    lockfiles_considered += 1
    ecosystem = LOCKFILE_ECOSYSTEMS[file.basename.to_s]
    dir = File.dirname(relative)
    dir = "" if dir == "."
    next if scopes_by_ecosystem[ecosystem].include?(dir)

    problems << "#{relative}: committed #{ecosystem} lockfile in a directory no #{CONFIG} entry names, " \
                "so it receives no VERSION updates. Security updates still arrive, because those run " \
                "from Dependabot alerts rather than this config — which is exactly what makes the gap " \
                "hard to see: a trickle of security-only PRs reads like a maintained directory. " \
                "Left alone it drifts onto majors the eventual patch was never backported to, and the " \
                "security update it does get becomes unappliable. " \
                "Add a `#{ecosystem}` entry with `directory: \"/#{dir}\"`#{dir.empty? ? ' (root)' : ''}, " \
                "or delete the lockfile."
  end

  # ---- 3. Catch-all
  entries.each do |entry|
    next if entry.has_catch_all

    problems << "#{CONFIG}: updates[#{entry.index}]: the #{entry.ecosystem} entry for \"#{entry.directory}\" has no " \
                "catch-all group, so every routine bump opens its own PR and " \
                "`open-pull-requests-limit` becomes a coverage ceiling rather than a noise control: " \
                "once it is reached Dependabot stops proposing, with no failure and no signal. " \
                "Add a group with `patterns: [\"*\"]` (block or inline), excluding the named groups above it, " \
                "and for package ecosystems scope it to `update-types: [\"minor\", \"patch\"]` so a major " \
                "still arrives on its own."
  end

  # ---- 4. pnpm override ceilings (only when the file exists)
  overrides_scanned = 0
  override_files = files_named(root, %w[pnpm-workspace.yaml])
  override_files.each do |file|
    findings, scanned = scan_overrides(file)
    overrides_scanned += scanned
    findings.each do |finding|
      relative = Pathname(finding[:file]).relative_path_from(root).to_s
      problems << "#{relative}:#{finding[:line]}: override `#{finding[:key]}: #{finding[:value]}` is an exact " \
                  "version. Dependabot cannot edit this file, so that pin is a permanent CEILING: the " \
                  "next advisory against #{finding[:key]} will report `security_update_not_possible` and " \
                  "never open a PR. Use a range (`\"^#{finding[:value]}\"` or `\">=#{finding[:value]}\"`) — " \
                  "the lockfile still pins the resolution, so installs stay deterministic. " \
                  "If the ceiling is deliberate, annotate it with a `# pin: <reason>` comment."
    end
  end

  if problems.any?
    warn "Dependabot config check FAILED:\n"
    problems.each { |problem| warn "  - #{problem}\n" }
    exit 1
  end

  # Anti-vacuity, parameterized by what the repo actually claims.
  if !cargo_entries.empty? && manifests_scanned.zero?
    raise "scanned ZERO Cargo manifests under the configured cargo directories — fix the scanner"
  end
  require_lockfiles = ENV["DEPENDABOT_CHECK_REQUIRE_LOCKFILES"] == "1"
  if require_lockfiles && lockfiles_considered.zero?
    raise "found ZERO committed lockfiles to attribute — fix the scanner"
  end
  require_overrides = ENV["DEPENDABOT_CHECK_REQUIRE_OVERRIDES"] == "1"
  if require_overrides && overrides_scanned.zero?
    raise "read ZERO pnpm overrides — fix the scanner"
  end

  parts = [
    "#{entries.length} entries, all with a catch-all group",
  ]
  parts << "#{manifests_scanned} cargo manifest(s), none escaping scope" unless cargo_entries.empty?
  parts << "#{lockfiles_considered} lockfile(s), all covered" if lockfiles_considered.positive? || require_lockfiles
  parts << "#{overrides_scanned} override(s), none freezing a ceiling" if overrides_scanned.positive? || require_overrides
  puts "Dependabot config OK — #{parts.join('; ')}."
end

check!(repo_root) if $PROGRAM_NAME == __FILE__
