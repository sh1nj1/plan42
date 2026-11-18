# frozen_string_literal: true

require "test_helper"
require Rails.root.join("engines/collavre/db/migrate/20261016000000_add_trigger_comment_id_to_tasks")

class AddTriggerCommentIdToTasksTest < ActiveSupport::TestCase
  test "backfills numeric and string comment ids while ignoring absent or invalid ids" do
    tasks = [ 123, "456", nil, "", "invalid" ].map do |id|
      task = Collavre::Task.create!(name: "Legacy", agent: users(:one))
      task.update_columns(trigger_event_payload: { "comment" => { "id" => id } }, trigger_comment_id: nil)
      task
    end
    migration = AddTriggerCommentIdToTasks.new
    migration.stub(:add_column, nil) do
      migration.stub(:add_index, nil) { migration.up }
    end
    assert_equal [ 123, 456, nil, nil, nil ], tasks.map { |task| task.reload.trigger_comment_id }
    assert ActiveRecord::Base.connection.index_exists?(:tasks, :trigger_comment_id)
    migration.stub(:remove_column, ->(table, column) {
      assert_equal :tasks, table
      assert_equal :trigger_comment_id, column
    }) { migration.down }
  end
end
