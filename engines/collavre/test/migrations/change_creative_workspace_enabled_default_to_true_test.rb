require "test_helper"
require Rails.root.join(
  "engines/collavre/db/migrate/20260809000000_change_creative_workspace_enabled_default_to_true"
)

class ChangeCreativeWorkspaceEnabledDefaultToTrueTest < ActiveSupport::TestCase
  test "rollback is explicitly irreversible" do
    error = assert_raises(ActiveRecord::IrreversibleMigration) do
      ChangeCreativeWorkspaceEnabledDefaultToTrue.new.down
    end

    assert_match(/post-migration user opt-ins/, error.message)
  end
end
