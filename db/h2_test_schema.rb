# This file defines the H2 database schema for testing only.
# In production, H2 connects to an external MySQL database.
# This schema mirrors the external database structure for test purposes.
#
# DO NOT run migrations on this - it is manually maintained.

# This module allows loading schema into a specific connection
module H2TestSchema
  def self.load!(connection)
    connection.create_table "brain_organization", primary_key: "organization_idx", force: :cascade do |t|
      t.string "organization_name"
    end

    connection.create_table "brain_user", primary_key: "user_idx", force: :cascade do |t|
      t.string "name"
      t.string "date_of_birth"
      t.string "phone"
      t.integer "organization_idx"
      t.index ["organization_idx"], name: "index_brain_user_on_organization_idx"
    end

    connection.create_table "brain_assignment", primary_key: "assignment_idx", force: :cascade do |t|
      t.string "assignment_name"
    end

    connection.create_table "map_assignment_user", primary_key: "assignment_user_idx", force: :cascade do |t|
      t.integer "user"
      t.integer "assignment"
      t.date "assignment_user_start"
      t.date "assignment_user_end"
      t.integer "round"
      t.datetime "create_time"
      t.index ["user"], name: "index_map_assignment_user_on_user"
      t.index ["assignment"], name: "index_map_assignment_user_on_assignment"
    end

    # Tables required for backup_and_delete_round (cascading delete)
    connection.create_table "map_assignment_unit_user", primary_key: "assignment_unit_user_idx", force: :cascade do |t|
      t.integer "assignment_user"
      t.integer "assignment_unit"
      t.datetime "create_time"
      t.index ["assignment_user"], name: "index_mauu_on_assignment_user"
    end

    connection.create_table "assignment_log", primary_key: "idx", force: :cascade do |t|
      t.integer "assignment_user"
      t.string "log_type"
      t.text "log_content"
      t.datetime "create_time"
      t.index ["assignment_user"], name: "index_assignment_log_on_assignment_user"
    end

    connection.create_table "assignment_survey", primary_key: "id", force: :cascade do |t|
      t.integer "map_assignment_unit_user_id"
      t.integer "survey_id"
      t.string "status"
      t.datetime "create_time"
      t.index ["map_assignment_unit_user_id"], name: "index_assignment_survey_on_mauu_id"
    end

    connection.create_table "survey_result", primary_key: "idx", force: :cascade do |t|
      t.integer "assignment_survey_id"
      t.integer "question_id"
      t.text "answer"
      t.datetime "create_time"
      t.index ["assignment_survey_id"], name: "index_survey_result_on_as_id"
    end

    connection.create_table "learning_statistics", primary_key: "idx", force: :cascade do |t|
      t.integer "map_assignment_unit_user_idx"
      t.integer "total_count"
      t.integer "correct_count"
      t.float "score"
      t.datetime "create_time"
      t.index ["map_assignment_unit_user_idx"], name: "index_learning_stats_on_mauu_idx"
    end

    connection.create_table "learning_result", primary_key: "idx", force: :cascade do |t|
      t.integer "learning_statistics_idx"
      t.integer "question_idx"
      t.string "user_answer"
      t.boolean "is_correct"
      t.datetime "create_time"
      t.index ["learning_statistics_idx"], name: "index_learning_result_on_ls_idx"
    end
  end
end
