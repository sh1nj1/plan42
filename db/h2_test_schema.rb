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
  end
end
