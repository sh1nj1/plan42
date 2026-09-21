require "test_helper"

class MigrationVersionsTest < ActiveSupport::TestCase
  test "migration versions are unique across the host and engines" do
    migration_files = Dir[Rails.root.join("{db,engines/*/db}/migrate/[0-9]*_*.rb")]
    files_by_version = migration_files.group_by do |path|
      File.basename(path).split("_", 2).first
    end
    duplicates = files_by_version.select { |_version, paths| paths.many? }

    assert_empty duplicates, duplicate_message(duplicates)
  end

  private

  def duplicate_message(duplicates)
    duplicates.sort.map do |version, paths|
      "Migration version #{version} is duplicated:\n#{paths.sort.join("\n")}"
    end.join("\n\n")
  end
end
