# Model test for ActivityLog undo system
require "test_helper"

module Mis2
  class ActivityLogTest < ActiveSupport::TestCase
    fixtures :users

    setup do
      @user = users(:one)
      @performer = users(:one)
    end

    teardown do
      Mis2::ActivityLog.delete_all
      begin
        conn = Mis2::H2Record.connection
        conn.execute("DELETE FROM map_assignment_unit_user WHERE assignment_unit_user_idx IN (900, 901)")
        conn.execute("DELETE FROM map_assignment_user WHERE assignment_user_idx IN (900, 901, 902, 903)")
        Mis2::H2::Assignment.where(assignment_idx: 900).delete_all
        Mis2::H2::User.where(user_idx: 900).delete_all
        Mis2::H2::Organization.where(organization_idx: 900).delete_all
      rescue ActiveRecord::StatementInvalid
        # Ignore if H2 tables don't exist
      end
    end

    # --- undoable? ---

    test "undoable? returns true when undoable metadata and undone_at is nil" do
      log = Mis2::ActivityLog.create!(
        user: @user,
        user_name: @user.name,
        action: "h2_training_update",
        target_type: "Mis2::H2::AssignmentUser",
        target_id: "1",
        message: "Test update",
        metadata: { "undoable" => true, "database" => "h2", "operations" => [] }
      )

      assert log.undoable?
    end

    test "undoable? returns false when undoable is false" do
      log = Mis2::ActivityLog.create!(
        user: @user,
        user_name: @user.name,
        action: "h3_organization_approve",
        target_type: "Mis2::H3::OrganizationAdmin",
        target_id: "1",
        message: "Test approve",
        metadata: { "undoable" => false }
      )

      assert_not log.undoable?
    end

    test "undoable? returns false when undone_at is set" do
      log = Mis2::ActivityLog.create!(
        user: @user,
        user_name: @user.name,
        action: "h2_training_update",
        target_type: "Mis2::H2::AssignmentUser",
        target_id: "1",
        message: "Test update",
        metadata: { "undoable" => true, "database" => "h2", "operations" => [] },
        undone_at: Time.current
      )

      assert_not log.undoable?
    end

    test "undoable? returns false when metadata is nil" do
      log = Mis2::ActivityLog.create!(
        user: @user,
        user_name: @user.name,
        action: "test",
        target_type: "Test",
        target_id: "1",
        message: "Test",
        metadata: nil
      )

      assert_not log.undoable?
    end

    # --- undo! raises on non-undoable ---

    test "undo! raises error when not undoable" do
      log = Mis2::ActivityLog.create!(
        user: @user,
        user_name: @user.name,
        action: "h3_organization_approve",
        target_type: "Test",
        target_id: "1",
        message: "Test",
        metadata: { "undoable" => false }
      )

      error = assert_raises(RuntimeError) { log.undo!(performed_by: @performer) }
      assert_equal I18n.t("mis2.activity_logs.undo.not_undoable"), error.message
    end

    test "undo! raises error when operations are blank" do
      log = Mis2::ActivityLog.create!(
        user: @user,
        user_name: @user.name,
        action: "h2_training_update",
        target_type: "Test",
        target_id: "1",
        message: "Test",
        metadata: { "undoable" => true, "database" => "h2", "operations" => [] }
      )

      error = assert_raises(RuntimeError) { log.undo!(performed_by: @performer) }
      assert_equal I18n.t("mis2.activity_logs.undo.no_operations"), error.message
    end

    # --- undo! for update operations ---

    test "undo! reverts an update operation on H2" do
      ensure_h2_schema_loaded!

      # Create test data
      Mis2::H2::Organization.find_or_create_by!(organization_idx: 900) do |o|
        o.organization_name = "Undo Test Org"
      end
      Mis2::H2::User.find_or_create_by!(user_idx: 900) do |u|
        u.name = "Undo Test User"
        u.date_of_birth = "19900101"
        u.phone = "01011111111"
        u.organization_idx = 900
      end
      Mis2::H2::Assignment.find_or_create_by!(assignment_idx: 900) do |a|
        a.assignment_name = "Undo Test Training"
      end

      # Create assignment_user with new dates (simulating after update)
      conn = Mis2::H2Record.connection
      conn.execute(
        ActiveRecord::Base.sanitize_sql_array([
          "INSERT INTO map_assignment_user (assignment_user_idx, user, assignment, assignment_user_start, assignment_user_end, round, create_time) VALUES (?, ?, ?, ?, ?, ?, ?)",
          900, 900, 900, "2026-03-01", "2026-03-31", 1, Time.current.strftime("%Y-%m-%d %H:%M:%S")
        ])
      )

      # Create activity log for the update (old dates were 2026-01-01 ~ 2026-01-31)
      log = Mis2::ActivityLog.create!(
        user: @user,
        user_name: @user.name,
        action: "h2_training_update",
        target_type: "Mis2::H2::AssignmentUser",
        target_id: "900",
        message: "Test update",
        metadata: {
          "undoable" => true,
          "database" => "h2",
          "operations" => [
            {
              "type" => "update",
              "table" => "map_assignment_user",
              "primary_key" => "assignment_user_idx",
              "primary_key_value" => 900,
              "old_values" => {
                "assignment_user_start" => "2026-01-01",
                "assignment_user_end" => "2026-01-31"
              },
              "new_values" => {
                "assignment_user_start" => "2026-03-01",
                "assignment_user_end" => "2026-03-31"
              }
            }
          ]
        }
      )

      # Execute undo
      assert_difference "Mis2::ActivityLog.count", 1 do
        log.undo!(performed_by: @performer)
      end

      # Verify dates were reverted
      row = conn.select_one("SELECT * FROM map_assignment_user WHERE assignment_user_idx = 900")
      assert_equal "2026-01-01", row["assignment_user_start"].to_s
      assert_equal "2026-01-31", row["assignment_user_end"].to_s

      # Verify undone_at was set
      log.reload
      assert_not_nil log.undone_at
      assert_equal false, log.undoable?

      # Verify undo log was created
      undo_log = Mis2::ActivityLog.where(action: "undo").last
      assert_not_nil undo_log
      assert_equal "undo", undo_log.action
      assert_equal @performer.id, undo_log.user_id
      assert_equal false, undo_log.metadata["undoable"]
      assert_equal log.id, undo_log.metadata["original_log_id"]
    end

    # --- undo! for delete operations ---

    test "undo! restores deleted rows via INSERT" do
      ensure_h2_schema_loaded!

      conn = Mis2::H2Record.connection

      # Create activity log for a delete operation (rows were backed up)
      log = Mis2::ActivityLog.create!(
        user: @user,
        user_name: @user.name,
        action: "h2_training_delete",
        target_type: "Mis2::H2::AssignmentUser",
        target_id: "901",
        message: "Test delete",
        metadata: {
          "undoable" => true,
          "database" => "h2",
          "operations" => [
            {
              "type" => "delete",
              "table" => "map_assignment_unit_user",
              "primary_key" => "assignment_unit_user_idx",
              "rows" => [
                { "assignment_unit_user_idx" => 901, "assignment_user" => 901, "assignment_unit" => 1 }
              ]
            },
            {
              "type" => "delete",
              "table" => "map_assignment_user",
              "primary_key" => "assignment_user_idx",
              "rows" => [
                { "assignment_user_idx" => 901, "user" => 901, "assignment" => 901, "assignment_user_start" => "2026-01-01", "assignment_user_end" => "2026-01-31", "round" => 1 }
              ]
            }
          ]
        }
      )

      # Ensure rows do not exist before undo
      assert_equal 0, conn.select_value("SELECT COUNT(*) FROM map_assignment_user WHERE assignment_user_idx = 901")
      assert_equal 0, conn.select_value("SELECT COUNT(*) FROM map_assignment_unit_user WHERE assignment_unit_user_idx = 901")

      # Execute undo - operations are reversed (root first: map_assignment_user, then child: map_assignment_unit_user)
      log.undo!(performed_by: @performer)

      # Verify rows were restored
      mau_row = conn.select_one("SELECT * FROM map_assignment_user WHERE assignment_user_idx = 901")
      assert_not_nil mau_row
      assert_equal 901, mau_row["user"]
      assert_equal 901, mau_row["assignment"]
      assert_equal "2026-01-01", mau_row["assignment_user_start"].to_s
      assert_equal "2026-01-31", mau_row["assignment_user_end"].to_s

      mauu_row = conn.select_one("SELECT * FROM map_assignment_unit_user WHERE assignment_unit_user_idx = 901")
      assert_not_nil mauu_row
      assert_equal 901, mauu_row["assignment_user"]

      # Verify undone_at was set
      log.reload
      assert_not_nil log.undone_at
    end

    # --- double undo prevention ---

    test "undo! cannot be called twice on the same log" do
      ensure_h2_schema_loaded!

      conn = Mis2::H2Record.connection

      # Create a simple update log
      conn.execute(
        ActiveRecord::Base.sanitize_sql_array([
          "INSERT INTO map_assignment_user (assignment_user_idx, user, assignment, assignment_user_start, assignment_user_end, round) VALUES (?, ?, ?, ?, ?, ?)",
          902, 902, 902, "2026-03-01", "2026-03-31", 1
        ])
      )

      log = Mis2::ActivityLog.create!(
        user: @user,
        user_name: @user.name,
        action: "h2_training_update",
        target_type: "Mis2::H2::AssignmentUser",
        target_id: "902",
        message: "Test update",
        metadata: {
          "undoable" => true,
          "database" => "h2",
          "operations" => [
            {
              "type" => "update",
              "table" => "map_assignment_user",
              "primary_key" => "assignment_user_idx",
              "primary_key_value" => 902,
              "old_values" => { "assignment_user_start" => "2026-01-01", "assignment_user_end" => "2026-01-31" },
              "new_values" => { "assignment_user_start" => "2026-03-01", "assignment_user_end" => "2026-03-31" }
            }
          ]
        }
      )

      # First undo should succeed
      log.undo!(performed_by: @performer)

      # Second undo should fail
      log.reload
      error = assert_raises(RuntimeError) { log.undo!(performed_by: @performer) }
      assert_equal I18n.t("mis2.activity_logs.undo.not_undoable"), error.message
    end

    # --- normalize_value ---

    test "normalize_value converts ISO8601 datetime to MySQL format" do
      log = Mis2::ActivityLog.new
      result = log.send(:normalize_value, "2025-11-14T10:38:38.000Z")
      assert_equal "2025-11-14 10:38:38", result
    end

    test "normalize_value leaves regular strings unchanged" do
      log = Mis2::ActivityLog.new
      result = log.send(:normalize_value, "hello world")
      assert_equal "hello world", result
    end

    test "normalize_value leaves nil unchanged" do
      log = Mis2::ActivityLog.new
      result = log.send(:normalize_value, nil)
      assert_nil result
    end

    test "normalize_value leaves integers unchanged" do
      log = Mis2::ActivityLog.new
      result = log.send(:normalize_value, 42)
      assert_equal 42, result
    end

    test "normalize_value handles ISO8601 with timezone offset" do
      log = Mis2::ActivityLog.new
      result = log.send(:normalize_value, "2025-06-15T09:30:00+09:00")
      # Should be converted to a datetime string
      assert_match(/\A\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\z/, result)
    end

    # --- undo log metadata ---

    test "undo creates a non-undoable activity log entry" do
      ensure_h2_schema_loaded!

      conn = Mis2::H2Record.connection
      conn.execute(
        ActiveRecord::Base.sanitize_sql_array([
          "INSERT INTO map_assignment_user (assignment_user_idx, user, assignment, assignment_user_start, assignment_user_end, round) VALUES (?, ?, ?, ?, ?, ?)",
          903, 903, 903, "2026-03-01", "2026-03-31", 1
        ])
      )

      log = Mis2::ActivityLog.create!(
        user: @user,
        user_name: @user.name,
        action: "h2_training_update",
        target_type: "Mis2::H2::AssignmentUser",
        target_id: "903",
        message: "Test update",
        metadata: {
          "undoable" => true,
          "database" => "h2",
          "operations" => [
            {
              "type" => "update",
              "table" => "map_assignment_user",
              "primary_key" => "assignment_user_idx",
              "primary_key_value" => 903,
              "old_values" => { "assignment_user_start" => "2026-01-01" },
              "new_values" => { "assignment_user_start" => "2026-03-01" }
            }
          ]
        }
      )

      log.undo!(performed_by: @performer)

      undo_log = Mis2::ActivityLog.where(action: "undo").last
      assert_not_nil undo_log
      assert_equal false, undo_log.metadata["undoable"]
      assert_equal log.id, undo_log.metadata["original_log_id"]
      assert_equal "h2_training_update", undo_log.metadata["original_action"]
      assert_equal log.target_type, undo_log.target_type
      assert_equal log.target_id, undo_log.target_id

      # Verify original log was marked as undone
      log.reload
      assert_not_nil log.undone_at
      assert_equal @performer.id, log.metadata["undone_by"]
      assert_equal undo_log.id, log.metadata["undo_log_id"]
    end
  end
end
