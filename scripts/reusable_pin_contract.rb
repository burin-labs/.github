# frozen_string_literal: true

require "json"
require "open3"
require "time"
require "yaml"

# Structural YAML queries used by the network-owning reusable workflow audit.
module ReusablePinContract
  OUTPUT_NAME = /[A-Za-z_][A-Za-z0-9_-]*/

  module_function

  def document(source)
    YAML.safe_load(source, aliases: true) || {}
  end

  def scalar_strings(value, strings = [])
    case value
    when Hash
      value.each_value { |child| scalar_strings(child, strings) }
    when Array
      value.each { |child| scalar_strings(child, strings) }
    when String
      strings << value
    end
    strings
  end

  def outputs_read(strings, job_id)
    job = Regexp.escape(job_id)
    output = OUTPUT_NAME.source
    patterns = [
      /needs\.#{job}\.outputs\.(#{output})/,
      /needs\.#{job}\.outputs\[['"](#{output})['"]\]/,
      /needs\[['"]#{job}['"]\]\.outputs\.(#{output})/,
      /needs\[['"]#{job}['"]\]\.outputs\[['"](#{output})['"]\]/
    ]
    strings.flat_map { |text| patterns.flat_map { |pattern| text.scan(pattern).flatten } }.uniq.sort
  end

  def uses_line(source, reference, claimed_lines)
    pattern = /^\s*uses:\s*['"]?#{Regexp.escape(reference)}['"]?\s*(?:#.*)?$/
    # A long reference is often folded onto the next line (`uses: >-`).
    folded_key = /^\s*uses:\s*(?:[>|][-+]?)?\s*(?:#.*)?$/
    folded_value = /^\s*['"]?#{Regexp.escape(reference)}['"]?\s*(?:#.*)?$/
    lines = source.lines
    index = lines.each_index.find do |candidate|
      next false if claimed_lines.include?(candidate)

      lines[candidate].match?(pattern) ||
        (lines[candidate].match?(folded_key) && lines[candidate + 1].to_s.match?(folded_value))
    end
    raise "could not locate reusable workflow reference #{reference.inspect}" unless index

    claimed_lines << index
    index + 1
  end

  def references(source, org:, policy_repo:)
    parsed = document(source)
    jobs = parsed.fetch("jobs", {})
    strings = scalar_strings(parsed)
    prefix = "#{org}/#{policy_repo}/"
    reference_pattern = %r{\A#{Regexp.escape(prefix)}(\.github/workflows/[A-Za-z0-9._-]+\.ya?ml)@([^\s'"#]+)\z}
    claimed_lines = []

    jobs.each_with_object([]) do |(job_id, job), references|
      next unless job.is_a?(Hash) && job["uses"].is_a?(String)

      match = reference_pattern.match(job["uses"])
      next unless match

      references << {
        job: job_id.to_s,
        workflow: match[1],
        ref: match[2],
        line: uses_line(source, job["uses"], claimed_lines),
        required_outputs: outputs_read(strings, job_id.to_s)
      }
    end
  end

  def declared_outputs(source)
    parsed = document(source)
    triggers = parsed["on"] || parsed[true]
    workflow_call = triggers.is_a?(Hash) ? triggers["workflow_call"] : nil
    outputs = workflow_call.is_a?(Hash) ? workflow_call["outputs"] : nil
    outputs.is_a?(Hash) ? outputs.keys.map(&:to_s).sort : []
  end

  # -------------------------------------------------------------------------
  # Execution paths and measured staleness
  # -------------------------------------------------------------------------
  #
  # A reusable workflow here often checks this repository out at its own ref
  # (`job.workflow_sha`) and runs scripts from it. A caller pinned to an old SHA
  # therefore runs old scripts even when the workflow FILE never changed: the
  # Smart Ship approval-carry fix (#351) landed only in scripts/smart-ship/, so
  # callers pinned at 80668ab7 kept the old behaviour while a check scoped to
  # smart-ship.yml reported 0 newer commits. Staleness is measured over every
  # path the workflow executes at its own ref, not over the workflow file.

  # Newer commits younger than this are listed but not flagged: a daily census
  # plus a working day for consumers to pick a change up.
  STALE_GRACE_SECONDS = 2 * 24 * 60 * 60

  # Paths a workflow executes that cannot be derived from its YAML.
  EXECUTION_PATHS_TABLE = File.join(__dir__, "reusable-pin-execution-paths.json")

  def execution_table(path = EXECUTION_PATHS_TABLE)
    JSON.parse(File.read(path)).fetch("workflows")
  end

  # Read-only view of the policy repository at one commit.
  class Tree
    attr_reader :ref

    def initialize(git_dir, ref)
      @git_dir = git_dir
      @ref = ref
      @types = {}
    end

    def type(path)
      @types.fetch(path) do
        out, _, status = Open3.capture3("git", "-C", @git_dir, "cat-file", "-t", "#{@ref}:#{path}")
        @types[path] = status.success? ? out.strip : nil
      end
    end

    def read(path)
      return nil unless type(path) == "blob"

      out, _, status = Open3.capture3("git", "-C", @git_dir, "show", "#{@ref}:#{path}")
      # Git emits bytes; runners often have a US-ASCII locale.
      status.success? ? out.force_encoding(Encoding::UTF_8) : nil
    end
  end

  def commit?(git_dir, ref)
    _, _, status = Open3.capture3("git", "-C", git_dir, "cat-file", "-e", "#{ref}^{commit}")
    status.success?
  end

  def own_ref_checkout?(step, org, policy_repo)
    return false unless step.is_a?(Hash) && step["uses"].to_s.start_with?("actions/checkout@")

    with = step["with"].is_a?(Hash) ? step["with"] : {}
    repository = with["repository"].to_s
    self_repo = repository == "#{org}/#{policy_repo}" || repository.include?("workflow_repository")
    self_repo && with["ref"].to_s.include?("workflow_sha")
  end

  def checkout_prefix(step)
    step.dig("with", "path").to_s.strip.delete_prefix("./").chomp("/")
  end

  # Path-shaped tokens in a step's text that sit under the checkout `prefix`,
  # returned relative to this repository's root.
  def path_tokens(text, prefix)
    pattern = if prefix.empty?
                %r{(?<![A-Za-z0-9._/$-])(?:\./)?([A-Za-z0-9._-]+/[A-Za-z0-9._/-]+)}
              else
                %r{(?<![A-Za-z0-9._-])(?:\./)?#{Regexp.escape(prefix)}/([A-Za-z0-9._/-]+)}
              end
    text.scan(pattern).flatten.map { |token| token.sub(%r{[/.]+\z}, "") }
  end

  # The unit of staleness for a referenced path: a script's directory (its
  # siblings are its modules), a top-level file itself, or a directory as is.
  # Nonexistent tokens are prose, not paths, and are dropped.
  def executed_path(tree, path)
    case tree.type(path)
    when "tree" then path
    when "blob"
      parts = path.split("/")
      parts.length >= 3 ? parts[0..-2].join("/") : path
    end
  end

  ACTION_ROOT_REFERENCE = %r{GITHUB_ACTION_PATH\}?/\.\./\.\./\.\./([A-Za-z0-9._/-]+)}

  def local_action_paths(tree, action_dir)
    source = tree.read("#{action_dir}/action.yml") || tree.read("#{action_dir}/action.yaml")
    return [] unless source

    source.scan(ACTION_ROOT_REFERENCE).flatten.filter_map { |path| executed_path(tree, path) }
  end

  def step_paths(tree, step, prefix)
    return [] unless step.is_a?(Hash)

    texts = [step["run"], step["working-directory"]].compact.map(&:to_s)
    texts << step["uses"].to_s if step["uses"].to_s.start_with?("./")
    paths = texts.flat_map { |text| path_tokens(text, prefix) }.filter_map { |path| executed_path(tree, path) }
    paths + paths.select { |path| path.start_with?(".github/actions/") }.flat_map { |dir| local_action_paths(tree, dir) }
  end

  # execution_paths -> { paths: [...], unresolved: [...] }
  #
  # Derived: the workflow file; workflows it calls with `uses: ./...`; for each
  # checkout of this repository at the workflow's own ref, its sparse-checkout
  # paths, local actions used from it, and paths its job's steps run or enter.
  # A checkout from which nothing could be derived is `unresolved` unless the
  # explicit table lists the workflow.
  def execution_paths(tree, workflow, org:, policy_repo:, table: execution_table, seen: [])
    return { paths: [], unresolved: [] } if seen.include?(workflow)

    seen << workflow
    source = tree.read(workflow)
    return { paths: [workflow], unresolved: ["#{workflow} is not readable at #{tree.ref[0, 12]}"] } unless source

    paths = [workflow]
    unresolved = []
    jobs = document(source)["jobs"]
    (jobs.is_a?(Hash) ? jobs : {}).each do |job_id, job|
      next unless job.is_a?(Hash)

      if (nested = job["uses"].to_s[%r{\A\./(\.github/workflows/[A-Za-z0-9._-]+\.ya?ml)\z}, 1])
        result = execution_paths(tree, nested, org: org, policy_repo: policy_repo, table: table, seen: seen)
        paths.concat(result[:paths])
        unresolved.concat(result[:unresolved])
      end

      steps = job["steps"].is_a?(Array) ? job["steps"] : []
      steps.each do |step|
        next unless own_ref_checkout?(step, org, policy_repo)

        prefix = checkout_prefix(step)
        sparse = step.dig("with", "sparse-checkout").to_s.lines.map(&:strip)
                     .reject { |line| line.empty? || line.start_with?("!", "#") }
                     .map { |line| line.delete_prefix("/").chomp("/") }
        derived = (sparse + steps.flat_map { |candidate| step_paths(tree, candidate, prefix) }).uniq
        if derived.empty?
          where = prefix.empty? ? "the workspace root" : prefix
          unresolved << "#{workflow} job #{job_id} checks out #{org}/#{policy_repo} at its own ref into " \
                        "#{where}, but no path it executes could be derived"
        end
        paths.concat(derived)
      end
    end

    paths.concat(Array(table.dig(workflow, "paths")))
    { paths: paths.uniq.sort, unresolved: unresolved.uniq }
  end

  # staleness -> one record per (workflow, pinned commit):
  #   current  no commit to main since the pin touched an execution path
  #   pending  some did, and the oldest is within STALE_GRACE_SECONDS
  #   stale    some did, and the oldest is older than that
  #   unknown  the pin, target, workflow or its paths could not be read; never clean
  def staleness(git_dir:, workflow:, pinned:, target:, org:, policy_repo:, now: Time.now.to_i,
                table: execution_table)
    record = { workflow: workflow, pinned: pinned, target: target, state: "unknown", count: nil,
               paths: [], commits: [], oldest_age_seconds: nil, detail: "" }
    unknown = ->(detail) { record.merge(detail: detail) }

    return unknown.call("pinned commit #{pinned[0, 8]} is not readable in #{org}/#{policy_repo}") unless commit?(git_dir, pinned)
    return unknown.call("target commit #{target[0, 8]} is not readable in #{org}/#{policy_repo}") unless commit?(git_dir, target)

    pinned_tree = Tree.new(git_dir, pinned)
    target_tree = Tree.new(git_dir, target)
    return unknown.call("#{workflow} does not exist at the pinned commit") unless pinned_tree.read(workflow)

    trees = [pinned_tree]
    trees << target_tree if target_tree.read(workflow)
    derived = trees.map { |tree| execution_paths(tree, workflow, org: org, policy_repo: policy_repo, table: table) }
    paths = derived.flat_map { |result| result[:paths] }.uniq.sort
    unresolved = derived.flat_map { |result| result[:unresolved] }.uniq
    record = record.merge(paths: paths)
    if unresolved.any? && !table.key?(workflow)
      return unknown.call("execution paths are incomplete: #{unresolved.join('; ')}")
    end

    out, err, status = Open3.capture3(
      "git", "-C", git_dir, "log", "--format=%H%x1f%ct%x1f%s", "#{pinned}..#{target}", "--", *paths
    )
    return unknown.call("git log failed: #{err.strip}") unless status.success?

    commits = out.force_encoding(Encoding::UTF_8).lines.map do |line|
      sha, time, subject = line.chomp.split("\x1f", 3)
      { sha: sha, committed_at: Time.at(time.to_i).utc.iso8601, subject: subject.to_s, time: time.to_i }
    end
    oldest = commits.map { |commit| commit[:time] }.min
    state = if commits.empty? then "current"
            elsif now - oldest > STALE_GRACE_SECONDS then "stale"
            else "pending"
            end
    record.merge(
      state: state,
      count: commits.length,
      commits: commits.map { |commit| commit.except(:time) },
      oldest_age_seconds: oldest && (now - oldest),
      detail: commits.empty? ? "no newer commits touch the execution paths" : "#{commits.length} newer commit(s)"
    )
  end
end

if $PROGRAM_NAME == __FILE__
  command = ARGV.shift
  # Workflow bodies are UTF-8 whatever the caller's locale is.
  $stdin.set_encoding(Encoding::UTF_8)
  usage = "usage: reusable_pin_contract.rb references ORG POLICY_REPO | declared-outputs | " \
          "staleness GIT_DIR ORG POLICY_REPO WORKFLOW PINNED TARGET [NOW_EPOCH]"

  result = case command
           when "references"
             org = ARGV.shift
             policy_repo = ARGV.shift
             abort usage unless org && policy_repo
             ReusablePinContract.references($stdin.read, org: org, policy_repo: policy_repo)
           when "declared-outputs"
             ReusablePinContract.declared_outputs($stdin.read)
           when "staleness"
             git_dir, org, policy_repo, workflow, pinned, target, now = ARGV
             abort usage unless git_dir && org && policy_repo && workflow && pinned && target
             ReusablePinContract.staleness(
               git_dir: git_dir, org: org, policy_repo: policy_repo, workflow: workflow,
               pinned: pinned, target: target, now: (now || Time.now).to_i
             )
           else
             abort usage
           end

  puts JSON.generate(result)
end
