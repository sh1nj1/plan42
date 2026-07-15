# frozen_string_literal: true

# SimpleCov bootstrap for the host app and all engines.
#
# Activated only when the COVERAGE environment variable is set, so ordinary test
# runs — including the pre-push hook and CI — are completely unaffected. This
# file must be required BEFORE any application code is loaded (i.e. before
# config/environment) so SimpleCov can instrument every file as it is loaded.
#
# The whole suite (host app + all engines) runs in a single `bin/rails test`
# process via `rake test`, so one SimpleCov run aggregates everything. Minitest
# parallelization forks worker processes; the parallelize_setup/teardown hooks in
# the test helpers give each worker a distinct command name and flush its result,
# which the primary process then merges into the final report.
return unless ENV["COVERAGE"]

require "simplecov"
require "simplecov-lcov"

SimpleCov::Formatter::LcovFormatter.config.report_with_single_file = true
SimpleCov.formatters = SimpleCov::Formatter::MultiFormatter.new(
  [
    SimpleCov::Formatter::HTMLFormatter,
    SimpleCov::Formatter::LcovFormatter
  ]
)

SimpleCov.start "rails" do
  enable_coverage :branch
  command_name "MiniTest"
  # Keep partial results from forked workers mergeable across the whole run.
  merge_timeout 3600

  # Group each engine so per-engine coverage is visible alongside the host app.
  Dir.glob(File.expand_path("../../engines/*", __dir__)).each do |engine_path|
    next unless File.directory?(engine_path)

    engine = File.basename(engine_path)
    add_group "engine: #{engine}", "engines/#{engine}/"
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
