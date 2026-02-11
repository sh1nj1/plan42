# This file defines the H3 database schema for testing only.
# In production, H3 connects to an external MySQL database.
# This schema mirrors the external database structure for test purposes.
#
# DO NOT run migrations on this - it is manually maintained.

module H3TestSchema
  def self.load!(connection)
    connection.create_table "organization", force: :cascade do |t|
      t.string "name"
      t.string "code"
      t.string "type"
      t.boolean "active_yn", default: false
      t.boolean "deleted_yn", default: false
      t.datetime "created_at"
      t.string "created_by"
      t.datetime "modified_at"
      t.string "modified_by"
    end

    connection.create_table "organization_department", force: :cascade do |t|
      t.bigint "organization_id"
      t.string "medical_specialty"
      t.boolean "active_yn", default: true
      t.boolean "deleted_yn", default: false
      t.datetime "created_at"
      t.string "created_by"
      t.datetime "modified_at"
      t.string "modified_by"
      t.index ["organization_id"], name: "idx_org_dept_org_id"
    end

    connection.create_table "organization_admin", force: :cascade do |t|
      t.bigint "organization_department_id"
      t.string "login_id"
      t.string "password"
      t.string "name"
      t.string "phone"
      t.string "role"
      t.string "status"
      t.datetime "created_at"
      t.string "created_by"
      t.datetime "modified_at"
      t.string "modified_by"
      t.index ["organization_department_id"], name: "idx_org_admin_dept_id"
    end
  end
end
