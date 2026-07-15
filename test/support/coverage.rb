# frozen_string_literal: true

# SimpleCov bootstrap for the host app and all engines.
#
# Activated only when the COVERAGE environment variable is set, so ordinary test
# runs — including the pre-push hook and CI — are completely unaffected. This
# file must be required BEFORE any application code is loaded (i.e. before
# config/environment) so SimpleCov can instrument every file as it is loaded.
#
# CI runs the unit/integration suite (`rake test`) and the system suite
# (`rake test:system`) as separate, sequential `bin/rails test` subprocesses
# (and `test:system` shells out once per engine), each producing its own
# SimpleCov result. They accumulate into one report via the shared
# `coverage/.resultset.json` (merge_timeout keeps every slice mergeable).
# Minitest parallelization forks worker processes; the parallelize_setup/teardown
# hooks in the test helpers give each worker a command name and flush its result.
# Because those names derive from the base below, the base MUST be unique per
# process (see command_name) — otherwise the second invocation's workers land on
# the same resultset keys as the first and overwrite them (sequential runs
# overwrite; only concurrent siblings combine), silently dropping the earlier
# suite from the merged lcov.
return unless ENV["COVERAGE"]

require "simplecov"
require "simplecov-lcov"

# Emit a single lcov file at a deterministic path (coverage/lcov.info) so CI can
# upload it and generate the summary regardless of the checkout directory name.
# The default lcov file name is derived from the repo directory basename, which
# differs between the main checkout and git worktrees.
SimpleCov::Formatter::LcovFormatter.config.report_with_single_file = true
SimpleCov::Formatter::LcovFormatter.config.single_report_path = File.join(SimpleCov.coverage_path, "lcov.info")
SimpleCov.formatters = SimpleCov::Formatter::MultiFormatter.new(
  [
    SimpleCov::Formatter::HTMLFormatter,
    SimpleCov::Formatter::LcovFormatter
  ]
)

SimpleCov.start "rails" do
  enable_coverage :branch
  # Unique per process: `rake test` and `rake test:system` run as separate
  # sequential subprocesses that share coverage/.resultset.json. The worker hooks
  # append "-#{worker}" to this base, so a fixed base ("MiniTest") makes both
  # invocations write the same "MiniTest-<worker>" keys — the later run overwrites
  # the earlier suite's slice. Process.pid keeps every subprocess's keys disjoint
  # so all suites accumulate. (CI starts from a clean checkout; for repeated local
  # runs clear coverage/ first so stale prior-PID slices aren't merged in.)
  command_name "MiniTest-#{Process.pid}"
  # Keep partial results from forked workers mergeable across the whole run.
  merge_timeout 3600

  # The built-in "rails" profile only disk-discovers unloaded files under the
  # host app via "{app,lib}/**/*.rb", so engine source that no test happens to
  # load is absent from the report entirely (missing from both numerator and
  # denominator) rather than counted as 0%. That inflates coverage for any engine
  # with unexercised files, and — since test env sets eager_load =
  # ENV["CI"].present? — makes local (unloaded) and CI (eager-loaded) numbers
  # disagree. `cover` injects those unloaded engine files at 0% AND scopes the
  # report to the host + engine source universe; host globs are listed so the
  # host app isn't dropped once a `cover` matcher is set. (`track_files` would do
  # the same discovery but is deprecated and emits a warning.)
  #
  # Match *.rake as well as *.rb: the profile counts loaded rake tasks (under
  # {app,lib}/tasks and engines/*/lib/tasks), so a *.rb-only `cover` glob would
  # silently drop them from the report — inflating coverage and making this
  # baseline non-comparable to the pre-`cover` numbers. Keep the universe a pure
  # superset: add unloaded engine source, drop nothing already counted.
  cover "{app,lib}/**/*.{rb,rake}", "engines/*/{app,lib}/**/*.{rb,rake}"

  # Group each engine so per-engine coverage is visible alongside the host app.
  Dir.glob(File.expand_path("../../engines/*", __dir__)).each do |engine_path|
    next unless File.directory?(engine_path)

    engine = File.basename(engine_path)
    group "engine: #{engine}", "engines/#{engine}/"
  end

  # Exclude test scaffolding, config, migrations, and generated/vendored code.
  skip %r{/test/}
  skip %r{/spec/}
  skip %r{/config/}
  skip %r{/db/}
  skip %r{/vendor/}
  skip %r{/bin/}
  skip %r{/node_modules/}
end
