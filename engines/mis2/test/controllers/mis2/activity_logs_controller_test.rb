# Controller test for ActivityLogs (undo action)
require "test_helper"

module Mis2
  class ActivityLogsControllerTest < ActionDispatch::IntegrationTest
    fixtures :users

    setup do
      ensure_h2_schema_loaded!

      @user = users(:one)
      sign_in_as(@user)
    end

    teardown do
      Mis2::ActivityLog.delete_all
      conn = Mis2::H2Record.connection
      conn.execute("DELETE FROM map_assignment_user WHERE assignment_user_idx IN (800, 801, 802)")
      conn.execute("DELETE FROM map_assignment_unit_user WHERE assignment_unit_user_idx IN (800, 801)")
    rescue ActiveRecord::StatementInvalid
      # Ignore if H2 tables don't exist (parallel test worker without schema)
    end

    # --- index ---

    test "index shows activity logs" do
      Mis2::ActivityLog.create!(
        user: @user,
        user_name: @user.name,
        action: "h2_training_update",
        target_type: "Mis2::H2::AssignmentUser",
        target_id: "1",
        message: "Updated training dates",
        metadata: { "undoable" => true }
      )

      get mis2.activity_logs_path
      assert_response :success
      assert_match "Updated training dates", response.body
    end

    # --- show ---

    test "show displays activity log detail with labels" do
      log = Mis2::ActivityLog.create!(
        user: @user,
        user_name: @user.name,
        action: "h2_training_update",
        target_type: "Mis2::H2::AssignmentUser",
        target_id: "123",
        message: "Updated training dates",
        metadata: { "undoable" => true, "database" => "h2", "some_key" => "some_value" }
      )

      get mis2.activity_log_path(log)
      assert_response :success

      # Verify labels are present
      assert_match I18n.t("mis2.activity_logs.show.title"), response.body
      assert_match I18n.t("mis2.activity_logs.show.id"), response.body
      assert_match I18n.t("mis2.activity_logs.show.action"), response.body
      assert_match I18n.t("mis2.activity_logs.show.target_type"), response.body
      assert_match I18n.t("mis2.activity_logs.show.target_id"), response.body
      assert_match I18n.t("mis2.activity_logs.show.metadata"), response.body

      # Verify values are present
      assert_match "h2_training_update", response.body
      assert_match "Mis2::H2::AssignmentUser", response.body
      assert_match "123", response.body
      assert_match "Updated training dates", response.body

      # Verify metadata is shown as YAML
      assert_match "some_key", response.body
      assert_match "some_value", response.body
    end

    test "show displays undone status for restored log" do
      log = Mis2::ActivityLog.create!(
        user: @user,
        user_name: @user.name,
        action: "h2_training_update",
        target_type: "Mis2::H2::AssignmentUser",
        target_id: "1",
        message: "Test update",
        metadata: { "undoable" => true },
        undone_at: Time.current
      )

      get mis2.activity_log_path(log)
      assert_response :success
      assert_match I18n.t("mis2.activity_logs.table.undone_status"), response.body
    end

    test "show displays restore button for undoable log" do
      log = Mis2::ActivityLog.create!(
        user: @user,
        user_name: @user.name,
        action: "h2_training_update",
        target_type: "Mis2::H2::AssignmentUser",
        target_id: "1",
        message: "Test update",
        metadata: { "undoable" => true, "database" => "h2", "operations" => [ { "type" => "update" } ] }
      )

      get mis2.activity_log_path(log)
      assert_response :success
      assert_match I18n.t("mis2.activity_logs.table.undo_button"), response.body
    end

    test "index shows detail button linking to show page" do
      log = Mis2::ActivityLog.create!(
        user: @user,
        user_name: @user.name,
        action: "h2_training_update",
        target_type: "Mis2::H2::AssignmentUser",
        target_id: "1",
        message: "Test update",
        metadata: { "undoable" => true }
      )

      get mis2.activity_logs_path
      assert_response :success
      assert_match I18n.t("mis2.activity_logs.table.detail_button"), response.body
      assert_match mis2.activity_log_path(log), response.body
    end

    # --- undo for update operations ---

    test "undo reverts an update operation and redirects with success" do
      conn = Mis2::H2Record.connection
      conn.execute(
        ActiveRecord::Base.sanitize_sql_array([
          "INSERT INTO map_assignment_user (assignment_user_idx, user, assignment, assignment_user_start, assignment_user_end, round) VALUES (?, ?, ?, ?, ?, ?)",
          800, 800, 800, "2026-03-01", "2026-03-31", 1
        ])
      )

      log = Mis2::ActivityLog.create!(
        user: @user,
        user_name: @user.name,
        action: "h2_training_update",
        target_type: "Mis2::H2::AssignmentUser",
        target_id: "800",
        message: "Test update",
        metadata: {
          "undoable" => true,
          "database" => "h2",
          "operations" => [
            {
              "type" => "update",
              "table" => "map_assignment_user",
              "primary_key" => "assignment_user_idx",
              "primary_key_value" => 800,
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

      assert_difference "Mis2::ActivityLog.count", 1 do
        patch mis2.undo_activity_log_path(log)
      end

      assert_redirected_to mis2.activity_logs_path
      follow_redirect!
      assert_match I18n.t("mis2.activity_logs.undo.success"), response.body

      # Verify dates were reverted
      row = conn.select_one("SELECT * FROM map_assignment_user WHERE assignment_user_idx = 800")
      assert_equal "2026-01-01", row["assignment_user_start"].to_s
      assert_equal "2026-01-31", row["assignment_user_end"].to_s

      # Verify log was marked as undone
      log.reload
      assert_not_nil log.undone_at
    end

    # --- undo for delete operations ---

    test "undo restores deleted rows and redirects with success" do
      conn = Mis2::H2Record.connection

      log = Mis2::ActivityLog.create!(
        user: @user,
        user_name: @user.name,
        action: "h2_training_delete",
        target_type: "Mis2::H2::AssignmentUser",
        target_id: "801",
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
                { "assignment_unit_user_idx" => 800, "assignment_user" => 801, "assignment_unit" => 1 }
              ]
            },
            {
              "type" => "delete",
              "table" => "map_assignment_user",
              "primary_key" => "assignment_user_idx",
              "rows" => [
                { "assignment_user_idx" => 801, "user" => 800, "assignment" => 800, "assignment_user_start" => "2026-01-01", "assignment_user_end" => "2026-01-31", "round" => 1 }
              ]
            }
          ]
        }
      )

      patch mis2.undo_activity_log_path(log)

      assert_redirected_to mis2.activity_logs_path

      # Verify rows were restored (reverse order: map_assignment_user first, then map_assignment_unit_user)
      mau_row = conn.select_one("SELECT * FROM map_assignment_user WHERE assignment_user_idx = 801")
      assert_not_nil mau_row, "map_assignment_user row should be restored"
      assert_equal 800, mau_row["user"]

      mauu_row = conn.select_one("SELECT * FROM map_assignment_unit_user WHERE assignment_unit_user_idx = 800")
      assert_not_nil mauu_row, "map_assignment_unit_user row should be restored"
      assert_equal 801, mauu_row["assignment_user"]
    end

    # --- undo not_undoable ---

    test "undo redirects with alert for non-undoable log" do
      log = Mis2::ActivityLog.create!(
        user: @user,
        user_name: @user.name,
        action: "h3_organization_approve",
        target_type: "Mis2::H3::OrganizationAdmin",
        target_id: "1",
        message: "Test approve",
        metadata: { "undoable" => false }
      )

      patch mis2.undo_activity_log_path(log)

      assert_redirected_to mis2.activity_logs_path
      follow_redirect!
      assert_match I18n.t("mis2.activity_logs.undo.not_undoable"), response.body
    end

    # --- undo already-undone log ---

    test "undo redirects with alert for already-undone log" do
      log = Mis2::ActivityLog.create!(
        user: @user,
        user_name: @user.name,
        action: "h2_training_update",
        target_type: "Mis2::H2::AssignmentUser",
        target_id: "1",
        message: "Test update",
        metadata: { "undoable" => true, "database" => "h2", "operations" => [ { "type" => "update", "table" => "map_assignment_user", "primary_key" => "assignment_user_idx", "primary_key_value" => 1, "old_values" => {} } ] },
        undone_at: Time.current
      )

      patch mis2.undo_activity_log_path(log)

      assert_redirected_to mis2.activity_logs_path
      follow_redirect!
      assert_match I18n.t("mis2.activity_logs.undo.not_undoable"), response.body
    end

    # --- undo for nonexistent log ---

    test "undo with nonexistent log redirects with error" do
      patch mis2.undo_activity_log_path(id: 99999)

      assert_redirected_to mis2.activity_logs_path
      follow_redirect!
      # The rescue => e catches RecordNotFound and shows error message
      assert_select "div", /Couldn't find|찾을 수 없/
    end

    # --- undo creates undo log entry ---

    test "undo creates a non-undoable undo log entry" do
      conn = Mis2::H2Record.connection
      conn.execute(
        ActiveRecord::Base.sanitize_sql_array([
          "INSERT INTO map_assignment_user (assignment_user_idx, user, assignment, assignment_user_start, assignment_user_end, round) VALUES (?, ?, ?, ?, ?, ?)",
          802, 802, 802, "2026-03-01", "2026-03-31", 1
        ])
      )

      log = Mis2::ActivityLog.create!(
        user: @user,
        user_name: @user.name,
        action: "h2_training_update",
        target_type: "Mis2::H2::AssignmentUser",
        target_id: "802",
        message: "Test update",
        metadata: {
          "undoable" => true,
          "database" => "h2",
          "operations" => [
            {
              "type" => "update",
              "table" => "map_assignment_user",
              "primary_key" => "assignment_user_idx",
              "primary_key_value" => 802,
              "old_values" => { "assignment_user_start" => "2026-01-01" },
              "new_values" => { "assignment_user_start" => "2026-03-01" }
            }
          ]
        }
      )

      patch mis2.undo_activity_log_path(log)

      undo_log = Mis2::ActivityLog.where(action: "undo").last
      assert_not_nil undo_log
      assert_equal "undo", undo_log.action
      assert_equal @user.id, undo_log.user_id
      assert_equal false, undo_log.metadata["undoable"]
      assert_equal log.id, undo_log.metadata["original_log_id"]
      assert_equal "h2_training_update", undo_log.metadata["original_action"]
    end
  end
end
