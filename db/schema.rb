# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2025_12_01_065949) do
  create_table "action_text_rich_texts", force: :cascade do |t|
    t.text "body"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.datetime "updated_at", null: false
    t.index ["record_type", "record_id", "name"], name: "index_action_text_rich_texts_uniqueness", unique: true
  end

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "calendar_events", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "creative_id"
    t.datetime "end_time", null: false
    t.string "google_event_id", null: false
    t.string "html_link"
    t.datetime "start_time", null: false
    t.string "summary"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["creative_id"], name: "index_calendar_events_on_creative_id"
    t.index ["google_event_id"], name: "index_calendar_events_on_google_event_id", unique: true
    t.index ["user_id"], name: "index_calendar_events_on_user_id"
  end

  create_table "comment_read_pointers", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "creative_id", null: false
    t.integer "last_read_comment_id"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["creative_id"], name: "index_comment_read_pointers_on_creative_id"
    t.index ["user_id", "creative_id"], name: "index_comment_read_pointers_on_user_id_and_creative_id", unique: true
    t.index ["user_id"], name: "index_comment_read_pointers_on_user_id"
  end

  create_table "comments", force: :cascade do |t|
    t.text "action"
    t.datetime "action_executed_at"
    t.integer "action_executed_by_id"
    t.integer "approver_id"
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.integer "creative_id", null: false
    t.boolean "private", default: false, null: false
    t.datetime "updated_at", null: false
    t.integer "user_id"
    t.index ["action_executed_by_id"], name: "index_comments_on_action_executed_by_id"
    t.index ["approver_id"], name: "index_comments_on_approver_id"
    t.index ["creative_id"], name: "index_comments_on_creative_id"
    t.index ["user_id"], name: "index_comments_on_user_id"
  end

  create_table "contacts", force: :cascade do |t|
    t.integer "contact_user_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["contact_user_id"], name: "index_contacts_on_contact_user_id"
    t.index ["user_id", "contact_user_id"], name: "index_contacts_on_user_id_and_contact_user_id", unique: true
    t.index ["user_id"], name: "index_contacts_on_user_id"
  end

  create_table "creative_expanded_states", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "creative_id"
    t.json "expanded_status", default: {}, null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["creative_id", "user_id"], name: "index_creative_expanded_states_on_creative_id_and_user_id", unique: true
    t.index ["creative_id"], name: "index_creative_expanded_states_on_creative_id"
    t.index ["user_id"], name: "index_creative_expanded_states_on_user_id"
  end

  create_table "creative_hierarchies", id: false, force: :cascade do |t|
    t.integer "ancestor_id", null: false
    t.integer "descendant_id", null: false
    t.integer "generations", null: false
    t.index ["ancestor_id", "descendant_id", "generations"], name: "creative_anc_desc_idx", unique: true
    t.index ["descendant_id"], name: "creative_desc_idx"
  end

  create_table "creative_shares", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "creative_id", null: false
    t.integer "permission", default: 0, null: false
    t.integer "shared_by_id"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["creative_id", "user_id"], name: "index_creative_shares_on_creative_id_and_user_id", unique: true
    t.index ["creative_id"], name: "index_creative_shares_on_creative_id"
    t.index ["shared_by_id"], name: "index_creative_shares_on_shared_by_id"
    t.index ["user_id"], name: "index_creative_shares_on_user_id"
  end

  create_table "creatives", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description", limit: 4294967295
    t.text "github_gemini_prompt"
    t.integer "origin_id"
    t.integer "parent_id"
    t.float "progress", default: 0.0
    t.integer "sequence", default: 0, null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["origin_id"], name: "index_creatives_on_origin_id"
    t.index ["parent_id"], name: "index_creatives_on_parent_id"
    t.index ["user_id"], name: "index_creatives_on_user_id"
  end

  create_table "devices", force: :cascade do |t|
    t.string "app_id"
    t.string "app_version"
    t.string "client_id", null: false
    t.datetime "created_at", null: false
    t.integer "device_type", null: false
    t.string "fcm_token", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["client_id"], name: "index_devices_on_client_id", unique: true
    t.index ["fcm_token"], name: "index_devices_on_fcm_token", unique: true
    t.index ["user_id"], name: "index_devices_on_user_id"
  end

  create_table "emails", force: :cascade do |t|
    t.text "body"
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "event", null: false
    t.string "subject", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id"
    t.index ["user_id"], name: "index_emails_on_user_id"
  end

  create_table "github_accounts", force: :cascade do |t|
    t.string "avatar_url"
    t.datetime "created_at", null: false
    t.string "github_uid", null: false
    t.string "login", null: false
    t.string "name"
    t.string "token", null: false
    t.datetime "token_expires_at"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["github_uid"], name: "index_github_accounts_on_github_uid", unique: true
    t.index ["user_id"], name: "index_github_accounts_on_user_id", unique: true
  end

  create_table "github_repository_links", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "creative_id", null: false
    t.integer "github_account_id", null: false
    t.string "repository_full_name", null: false
    t.bigint "repository_id"
    t.datetime "updated_at", null: false
    t.string "webhook_secret", null: false
    t.index ["creative_id", "repository_full_name"], name: "index_github_links_on_creative_and_repo", unique: true
    t.index ["creative_id"], name: "index_github_repository_links_on_creative_id"
    t.index ["github_account_id"], name: "index_github_repository_links_on_github_account_id"
    t.index ["repository_full_name"], name: "index_github_repository_links_on_repository_full_name"
  end

  create_table "inbox_items", force: :cascade do |t|
    t.integer "comment_id"
    t.datetime "created_at", null: false
    t.integer "creative_id"
    t.string "link"
    t.text "message"
    t.string "message_key"
    t.json "message_params", default: {}, null: false
    t.integer "owner_id", null: false
    t.string "state", default: "new", null: false
    t.datetime "updated_at", null: false
    t.index ["comment_id"], name: "index_inbox_items_on_comment_id"
    t.index ["creative_id"], name: "index_inbox_items_on_creative_id"
    t.index ["owner_id"], name: "index_inbox_items_on_owner_id"
    t.index ["state"], name: "index_inbox_items_on_state"
  end

  create_table "invitations", force: :cascade do |t|
    t.datetime "accepted_at"
    t.datetime "clicked_at"
    t.datetime "created_at", null: false
    t.integer "creative_id", null: false
    t.string "email"
    t.datetime "expires_at"
    t.integer "inviter_id", null: false
    t.integer "permission"
    t.datetime "updated_at", null: false
    t.index ["creative_id"], name: "index_invitations_on_creative_id"
    t.index ["inviter_id"], name: "index_invitations_on_inviter_id"
  end

  create_table "labels", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name"
    t.integer "owner_id"
    t.date "target_date"
    t.string "type"
    t.datetime "updated_at", null: false
    t.string "value"
    t.index ["owner_id"], name: "index_labels_on_owner_id"
  end

  create_table "notion_accounts", force: :cascade do |t|
    t.string "bot_id"
    t.datetime "created_at", null: false
    t.string "notion_uid", null: false
    t.string "token", null: false
    t.datetime "token_expires_at"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.string "workspace_id"
    t.string "workspace_name"
    t.index ["notion_uid"], name: "index_notion_accounts_on_notion_uid", unique: true
    t.index ["user_id"], name: "index_notion_accounts_on_user_id", unique: true
  end

  create_table "notion_block_links", force: :cascade do |t|
    t.string "block_id", null: false
    t.string "content_hash"
    t.datetime "created_at", null: false
    t.integer "creative_id", null: false
    t.integer "notion_page_link_id", null: false
    t.datetime "updated_at", null: false
    t.index ["creative_id"], name: "index_notion_block_links_on_creative_id"
    t.index ["notion_page_link_id", "block_id"], name: "index_notion_block_links_on_page_link_and_block", unique: true
    t.index ["notion_page_link_id"], name: "index_notion_block_links_on_notion_page_link_id"
  end

  create_table "notion_page_links", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "creative_id", null: false
    t.datetime "last_synced_at"
    t.integer "notion_account_id", null: false
    t.string "page_id", null: false
    t.string "page_title"
    t.string "page_url"
    t.string "parent_page_id"
    t.datetime "updated_at", null: false
    t.index ["creative_id", "page_id"], name: "index_notion_links_on_creative_and_page", unique: true
    t.index ["creative_id"], name: "index_notion_page_links_on_creative_id"
    t.index ["notion_account_id"], name: "index_notion_page_links_on_notion_account_id"
    t.index ["page_id"], name: "index_notion_page_links_on_page_id", unique: true
  end

  create_table "oauth_access_grants", force: :cascade do |t|
    t.integer "application_id", null: false
    t.datetime "created_at", null: false
    t.integer "expires_in", null: false
    t.text "redirect_uri", null: false
    t.integer "resource_owner_id", null: false
    t.datetime "revoked_at"
    t.string "scopes", default: "", null: false
    t.string "token", null: false
    t.index ["application_id"], name: "index_oauth_access_grants_on_application_id"
    t.index ["resource_owner_id"], name: "index_oauth_access_grants_on_resource_owner_id"
    t.index ["token"], name: "index_oauth_access_grants_on_token", unique: true
  end

  create_table "oauth_access_tokens", force: :cascade do |t|
    t.integer "application_id", null: false
    t.datetime "created_at", null: false
    t.integer "expires_in"
    t.string "previous_refresh_token", default: "", null: false
    t.string "refresh_token"
    t.integer "resource_owner_id"
    t.datetime "revoked_at"
    t.string "scopes"
    t.string "token", null: false
    t.index ["application_id"], name: "index_oauth_access_tokens_on_application_id"
    t.index ["refresh_token"], name: "index_oauth_access_tokens_on_refresh_token", unique: true
    t.index ["resource_owner_id"], name: "index_oauth_access_tokens_on_resource_owner_id"
    t.index ["token"], name: "index_oauth_access_tokens_on_token", unique: true
  end

  create_table "oauth_applications", force: :cascade do |t|
    t.boolean "confidential", default: true, null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "owner_id"
    t.string "owner_type"
    t.text "redirect_uri", null: false
    t.string "scopes", default: "", null: false
    t.string "secret", null: false
    t.string "uid", null: false
    t.datetime "updated_at", null: false
    t.index ["owner_id", "owner_type"], name: "index_oauth_applications_on_owner_id_and_owner_type"
    t.index ["uid"], name: "index_oauth_applications_on_uid", unique: true
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "solid_cable_messages", force: :cascade do |t|
    t.binary "channel", limit: 1024, null: false
    t.integer "channel_hash", limit: 8, null: false
    t.datetime "created_at", null: false
    t.binary "payload", limit: 536870912, null: false
    t.index ["channel"], name: "index_solid_cable_messages_on_channel"
    t.index ["channel_hash"], name: "index_solid_cable_messages_on_channel_hash"
    t.index ["created_at"], name: "index_solid_cable_messages_on_created_at"
  end

  create_table "solid_cache_entries", force: :cascade do |t|
    t.integer "byte_size", limit: 4, null: false
    t.datetime "created_at", null: false
    t.binary "key", limit: 1024, null: false
    t.integer "key_hash", limit: 8, null: false
    t.binary "value", limit: 536870912, null: false
    t.index ["byte_size"], name: "index_solid_cache_entries_on_byte_size"
    t.index ["key_hash", "byte_size"], name: "index_solid_cache_entries_on_key_hash_and_byte_size"
    t.index ["key_hash"], name: "index_solid_cache_entries_on_key_hash", unique: true
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.string "concurrency_key", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "error"
    t.bigint "job_id", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "active_job_id"
    t.text "arguments"
    t.string "class_name", null: false
    t.string "concurrency_key"
    t.datetime "created_at", null: false
    t.datetime "finished_at"
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at"
    t.datetime "updated_at", null: false
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "queue_name", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "hostname"
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.text "metadata"
    t.string "name", null: false
    t.integer "pid", null: false
    t.bigint "supervisor_id"
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.datetime "run_at", null: false
    t.string "task_key", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.text "arguments"
    t.string "class_name"
    t.string "command", limit: 2048
    t.datetime "created_at", null: false
    t.text "description"
    t.string "key", null: false
    t.integer "priority", default: 0
    t.string "queue_name"
    t.string "schedule", null: false
    t.boolean "static", default: true, null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "job_id", null: false
    t.integer "priority", default: 0, null: false
    t.string "queue_name", null: false
    t.datetime "scheduled_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "key", null: false
    t.datetime "updated_at", null: false
    t.integer "value", default: 1, null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "subscribers", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "creative_id", null: false
    t.string "email"
    t.datetime "updated_at", null: false
    t.index ["creative_id"], name: "index_subscribers_on_creative_id"
  end

  create_table "tags", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "creative_id", null: false
    t.integer "label_id"
    t.datetime "updated_at", null: false
    t.string "value"
    t.index ["label_id"], name: "index_tags_on_label_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "avatar_url"
    t.string "calendar_id"
    t.string "completion_mark", default: "", null: false
    t.datetime "created_at", null: false
    t.integer "created_by_id"
    t.integer "display_level", default: 6, null: false
    t.string "email", null: false
    t.datetime "email_verified_at"
    t.string "google_access_token"
    t.string "google_refresh_token"
    t.datetime "google_token_expires_at"
    t.string "google_uid"
    t.string "llm_api_key"
    t.string "llm_model"
    t.string "llm_vendor"
    t.string "locale"
    t.string "name", null: false
    t.boolean "notifications_enabled"
    t.string "password_digest", null: false
    t.boolean "searchable", default: false, null: false
    t.boolean "system_admin", default: false, null: false
    t.text "system_prompt"
    t.string "theme"
    t.string "timezone"
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["searchable"], name: "index_users_on_searchable"
    t.index ["system_admin"], name: "index_users_on_system_admin"
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "calendar_events", "creatives"
  add_foreign_key "calendar_events", "users"
  add_foreign_key "comment_read_pointers", "creatives"
  add_foreign_key "comment_read_pointers", "users"
  add_foreign_key "comments", "creatives"
  add_foreign_key "comments", "users"
  add_foreign_key "comments", "users", column: "action_executed_by_id"
  add_foreign_key "comments", "users", column: "approver_id"
  add_foreign_key "contacts", "users"
  add_foreign_key "contacts", "users", column: "contact_user_id"
  add_foreign_key "creative_expanded_states", "creatives"
  add_foreign_key "creative_expanded_states", "users"
  add_foreign_key "creative_shares", "creatives"
  add_foreign_key "creative_shares", "users"
  add_foreign_key "creative_shares", "users", column: "shared_by_id"
  add_foreign_key "creatives", "creatives", column: "origin_id"
  add_foreign_key "creatives", "creatives", column: "parent_id"
  add_foreign_key "creatives", "users"
  add_foreign_key "devices", "users"
  add_foreign_key "emails", "users"
  add_foreign_key "github_accounts", "users"
  add_foreign_key "github_repository_links", "creatives"
  add_foreign_key "github_repository_links", "github_accounts"
  add_foreign_key "inbox_items", "comments", on_delete: :nullify
  add_foreign_key "inbox_items", "creatives", on_delete: :nullify
  add_foreign_key "inbox_items", "users", column: "owner_id"
  add_foreign_key "invitations", "creatives"
  add_foreign_key "invitations", "users", column: "inviter_id"
  add_foreign_key "labels", "users", column: "owner_id"
  add_foreign_key "notion_accounts", "users"
  add_foreign_key "notion_block_links", "creatives"
  add_foreign_key "notion_block_links", "notion_page_links"
  add_foreign_key "notion_page_links", "creatives"
  add_foreign_key "notion_page_links", "notion_accounts"
  add_foreign_key "oauth_access_grants", "oauth_applications", column: "application_id"
  add_foreign_key "oauth_access_tokens", "oauth_applications", column: "application_id"
  add_foreign_key "sessions", "users"
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "subscribers", "creatives"
  add_foreign_key "tags", "labels"
end
