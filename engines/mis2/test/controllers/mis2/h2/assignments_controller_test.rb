# Controller test for H2 Assignments (destroy with backup, update with undo metadata)
require "test_helper"

module Mis2
  module H2
    class AssignmentsControllerTest < ActionDispatch::IntegrationTest
      fixtures :users

      setup do
        ensure_h2_schema_loaded!

        @user = users(:one)
        sign_in_as(@user)

        conn = Mis2::H2Record.connection

        # Create test organization, user, assignment
        @org = Mis2::H2::Organization.find_or_create_by!(organization_idx: 700) do |o|
          o.organization_name = "Test Org"
        end
        @h2_user = Mis2::H2::User.find_or_create_by!(user_idx: 700) do |u|
          u.name = "Test User"
          u.date_of_birth = "19900101"
          u.phone = "01000000000"
          u.organization_idx = 700
        end
        @assignment = Mis2::H2::Assignment.find_or_create_by!(assignment_idx: 700) do |a|
          a.assignment_name = "Test Training"
        end

        # Create map_assignment_user row
        conn.execute(
          ActiveRecord::Base.sanitize_sql_array([
            "INSERT INTO map_assignment_user (assignment_user_idx, user, assignment, assignment_user_start, assignment_user_end, round, create_time) VALUES (?, ?, ?, ?, ?, ?, ?)",
            700, 700, 700, "2026-01-01", "2026-01-31", 1, Time.current.strftime("%Y-%m-%d %H:%M:%S")
          ])
        )

        # Create related child rows for cascading delete test
        conn.execute(
          ActiveRecord::Base.sanitize_sql_array([
            "INSERT INTO map_assignment_unit_user (assignment_unit_user_idx, assignment_user, assignment_unit) VALUES (?, ?, ?)",
            700, 700, 1
          ])
        )
        conn.execute(
          ActiveRecord::Base.sanitize_sql_array([
            "INSERT INTO assignment_log (idx, assignment_user, log_type, log_content) VALUES (?, ?, ?, ?)",
            700, 700, "START", "Test log"
          ])
        )
        conn.execute(
          ActiveRecord::Base.sanitize_sql_array([
            "INSERT INTO assignment_survey (id, map_assignment_unit_user_id, survey_id, status) VALUES (?, ?, ?, ?)",
            700, 700, 1, "COMPLETED"
          ])
        )
        conn.execute(
          ActiveRecord::Base.sanitize_sql_array([
            "INSERT INTO survey_result (idx, assignment_survey_id, question_id, answer) VALUES (?, ?, ?, ?)",
            700, 700, 1, "Answer A"
          ])
        )
        conn.execute(
          ActiveRecord::Base.sanitize_sql_array([
            "INSERT INTO learning_statistics (idx, map_assignment_unit_user_idx, total_count, correct_count, score) VALUES (?, ?, ?, ?, ?)",
            700, 700, 10, 8, 80.0
          ])
        )
        conn.execute(
          ActiveRecord::Base.sanitize_sql_array([
            "INSERT INTO learning_result (idx, learning_statistics_idx, question_idx, user_answer, is_correct) VALUES (?, ?, ?, ?, ?)",
            700, 700, 1, "B", 1
          ])
        )
      end

      teardown do
        conn = Mis2::H2Record.connection
        conn.execute("DELETE FROM learning_result WHERE idx = 700")
        conn.execute("DELETE FROM learning_statistics WHERE idx = 700")
        conn.execute("DELETE FROM survey_result WHERE idx = 700")
        conn.execute("DELETE FROM assignment_survey WHERE id = 700")
        conn.execute("DELETE FROM assignment_log WHERE idx = 700")
        conn.execute("DELETE FROM map_assignment_unit_user WHERE assignment_unit_user_idx = 700")
        conn.execute("DELETE FROM map_assignment_user WHERE assignment_user_idx = 700")
        Mis2::H2::Assignment.where(assignment_idx: 700).delete_all
        Mis2::H2::User.where(user_idx: 700).delete_all
        Mis2::H2::Organization.where(organization_idx: 700).delete_all
        Mis2::ActivityLog.where(target_id: "700").delete_all
        Mis2::ActivityLog.where(action: "undo").delete_all
      rescue ActiveRecord::StatementInvalid
        # Ignore if H2 tables don't exist (parallel test worker without schema)
      end

      # --- destroy ---

      test "destroy deletes round and all related data" do
        conn = Mis2::H2Record.connection

        # Verify data exists before delete
        assert_equal 1, conn.select_value("SELECT COUNT(*) FROM map_assignment_user WHERE assignment_user_idx = 700")
        assert_equal 1, conn.select_value("SELECT COUNT(*) FROM map_assignment_unit_user WHERE assignment_user = 700")
        assert_equal 1, conn.select_value("SELECT COUNT(*) FROM learning_result WHERE learning_statistics_idx = 700")

        delete mis2.h2_assignment_path(700, user_idx: 700)

        assert_redirected_to mis2.edit_h2_assignment_path(700)

        # Verify all data was deleted
        assert_equal 0, conn.select_value("SELECT COUNT(*) FROM map_assignment_user WHERE assignment_user_idx = 700")
        assert_equal 0, conn.select_value("SELECT COUNT(*) FROM map_assignment_unit_user WHERE assignment_user = 700")
        assert_equal 0, conn.select_value("SELECT COUNT(*) FROM assignment_log WHERE assignment_user = 700")
        assert_equal 0, conn.select_value("SELECT COUNT(*) FROM assignment_survey WHERE map_assignment_unit_user_id = 700")
        assert_equal 0, conn.select_value("SELECT COUNT(*) FROM survey_result WHERE assignment_survey_id = 700")
        assert_equal 0, conn.select_value("SELECT COUNT(*) FROM learning_statistics WHERE map_assignment_unit_user_idx = 700")
        assert_equal 0, conn.select_value("SELECT COUNT(*) FROM learning_result WHERE learning_statistics_idx = 700")
      end

      test "destroy creates undoable activity log with operations" do
        assert_difference "Mis2::ActivityLog.count", 1 do
          delete mis2.h2_assignment_path(700, user_idx: 700)
        end

        log = Mis2::ActivityLog.where(action: "h2_training_delete").last
        assert_not_nil log
        assert_equal "h2_training_delete", log.action
        assert_equal @user.id, log.user_id
        assert_includes log.message, "Test Training"
        assert_includes log.message, "Test User"

        # Verify metadata
        assert_equal true, log.metadata["undoable"]
        assert_equal "h2", log.metadata["database"]

        # Verify operations array contains all 7 table backups
        operations = log.metadata["operations"]
        assert_not_nil operations
        tables = operations.map { |op| op["table"] }
        assert_includes tables, "learning_result"
        assert_includes tables, "learning_statistics"
        assert_includes tables, "survey_result"
        assert_includes tables, "assignment_survey"
        assert_includes tables, "assignment_log"
        assert_includes tables, "map_assignment_unit_user"
        assert_includes tables, "map_assignment_user"

        # Verify all operations are of type "delete"
        operations.each do |op|
          assert_equal "delete", op["type"]
        end

        # Verify backup rows contain data
        mau_op = operations.find { |op| op["table"] == "map_assignment_user" }
        assert_equal 1, mau_op["rows"].length
        assert_equal 700, mau_op["rows"][0]["assignment_user_idx"]
      end

      # --- destroy then undo (full round-trip) ---

      test "destroy then undo restores all data" do
        conn = Mis2::H2Record.connection

        # Delete the round
        delete mis2.h2_assignment_path(700, user_idx: 700)

        # Verify all data was deleted
        assert_equal 0, conn.select_value("SELECT COUNT(*) FROM map_assignment_user WHERE assignment_user_idx = 700")
        assert_equal 0, conn.select_value("SELECT COUNT(*) FROM map_assignment_unit_user WHERE assignment_user = 700")
        assert_equal 0, conn.select_value("SELECT COUNT(*) FROM learning_result WHERE learning_statistics_idx = 700")
        assert_equal 0, conn.select_value("SELECT COUNT(*) FROM learning_statistics WHERE map_assignment_unit_user_idx = 700")

        # Now undo it
        log = Mis2::ActivityLog.where(action: "h2_training_delete").last
        assert log.undoable?, "Activity log should be undoable"

        patch mis2.undo_activity_log_path(log)
        assert_redirected_to mis2.activity_logs_path

        # Verify all data was restored
        assert_equal 1, conn.select_value("SELECT COUNT(*) FROM map_assignment_user WHERE assignment_user_idx = 700")
        assert_equal 1, conn.select_value("SELECT COUNT(*) FROM map_assignment_unit_user WHERE assignment_user = 700")
        assert_equal 1, conn.select_value("SELECT COUNT(*) FROM assignment_log WHERE assignment_user = 700")
        assert_equal 1, conn.select_value("SELECT COUNT(*) FROM assignment_survey WHERE map_assignment_unit_user_id = 700")
        assert_equal 1, conn.select_value("SELECT COUNT(*) FROM survey_result WHERE assignment_survey_id = 700")
        assert_equal 1, conn.select_value("SELECT COUNT(*) FROM learning_statistics WHERE map_assignment_unit_user_idx = 700")
        assert_equal 1, conn.select_value("SELECT COUNT(*) FROM learning_result WHERE learning_statistics_idx = 700")

        # Verify specific row values
        mau = conn.select_one("SELECT * FROM map_assignment_user WHERE assignment_user_idx = 700")
        assert_equal 700, mau["user"]
        assert_equal 700, mau["assignment"]
        assert_equal 1, mau["round"]

        lr = conn.select_one("SELECT * FROM learning_result WHERE idx = 700")
        assert_equal "B", lr["user_answer"]

        # Verify the log is marked as undone
        log.reload
        assert_not_nil log.undone_at
        assert_not log.undoable?
      end

      # --- update ---

      test "update creates undoable activity log with update operation" do
        assert_difference "Mis2::ActivityLog.count", 1 do
          patch mis2.h2_assignment_path(700,
            user_idx: 700,
            start_date: "2026-02-01",
            end_date: "2026-02-28"
          )
        end

        assert_redirected_to mis2.edit_h2_assignment_path(700)

        log = Mis2::ActivityLog.where(action: "h2_training_update").last
        assert_not_nil log
        assert_equal true, log.metadata["undoable"]
        assert_equal "h2", log.metadata["database"]

        operations = log.metadata["operations"]
        assert_equal 1, operations.length

        op = operations.first
        assert_equal "update", op["type"]
        assert_equal "map_assignment_user", op["table"]
        assert_equal "assignment_user_idx", op["primary_key"]
        assert_equal 700, op["primary_key_value"]
        assert_equal "2026-01-01", op["old_values"]["assignment_user_start"]
        assert_equal "2026-01-31", op["old_values"]["assignment_user_end"]
        assert_equal "2026-02-01", op["new_values"]["assignment_user_start"]
        assert_equal "2026-02-28", op["new_values"]["assignment_user_end"]
      end

      # --- update then undo (full round-trip) ---

      test "update then undo reverts dates" do
        conn = Mis2::H2Record.connection

        # Update dates
        patch mis2.h2_assignment_path(700,
          user_idx: 700,
          start_date: "2026-06-01",
          end_date: "2026-06-30"
        )

        # Verify updated
        row = conn.select_one("SELECT * FROM map_assignment_user WHERE assignment_user_idx = 700")
        assert_equal "2026-06-01", row["assignment_user_start"].to_s
        assert_equal "2026-06-30", row["assignment_user_end"].to_s

        # Undo
        log = Mis2::ActivityLog.where(action: "h2_training_update").last
        patch mis2.undo_activity_log_path(log)

        # Verify reverted
        row = conn.select_one("SELECT * FROM map_assignment_user WHERE assignment_user_idx = 700")
        assert_equal "2026-01-01", row["assignment_user_start"].to_s
        assert_equal "2026-01-31", row["assignment_user_end"].to_s
      end
    end
  end
end
