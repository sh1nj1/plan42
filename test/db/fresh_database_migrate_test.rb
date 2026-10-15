# frozen_string_literal: true

require "test_helper"
require "open3"

# Fresh installs (the desktop app's first launch, a new deployment) build the
# schema by running every migration in order against an empty database, while
# the test suite only ever loads db/schema.rb. A migration that reaches for an
# app model sees the model's *current* enums and encrypted attributes against a
# table that is still missing their columns, and aborts the whole chain. Run
# the real chain so that only surfaces here.
class FreshDatabaseMigrateTest < ActiveSupport::TestCase
  test "every migration runs against an empty database" do
    Dir.mktmpdir("fresh-migrate") do |dir|
      env = {
        "RAILS_ENV" => "test",
        "DATABASE_URL" => "sqlite3:#{File.join(dir, 'fresh.sqlite3')}",
        "SCHEMA" => File.join(dir, "schema.rb")
      }
      output, status = Open3.capture2e(env, "bin/rails", "db:migrate", chdir: Rails.root.to_s)

      assert status.success?, "db:migrate failed on an empty database:\n#{output.lines.last(40).join}"
      assert_equal expected_schema_version, File.read(env["SCHEMA"])[/define\(version: ([\d_]+)\)/, 1]
    end
  end

  private

  def expected_schema_version
    File.read(Rails.root.join("db/schema.rb"))[/define\(version: ([\d_]+)\)/, 1]
  end
end
