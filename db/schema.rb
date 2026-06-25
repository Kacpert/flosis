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

ActiveRecord::Schema[8.1].define(version: 2026_06_26_000001) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

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

  create_table "briefs", force: :cascade do |t|
    t.datetime "briefed_at"
    t.bigint "chat_session_id"
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.string "status", default: "draft", null: false
    t.bigint "task_id", null: false
    t.datetime "updated_at", null: false
    t.integer "version", default: 1, null: false
    t.bigint "workspace_id", null: false
    t.index ["chat_session_id"], name: "index_briefs_on_chat_session_id"
    t.index ["task_id", "version"], name: "index_briefs_on_task_id_and_version", unique: true
    t.index ["task_id"], name: "index_briefs_on_task_id"
    t.index ["workspace_id"], name: "index_briefs_on_workspace_id"
  end

  create_table "chat_messages", force: :cascade do |t|
    t.bigint "chat_session_id", null: false
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.string "role", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["chat_session_id"], name: "index_chat_messages_on_chat_session_id"
    t.index ["user_id"], name: "index_chat_messages_on_user_id"
  end

  create_table "chat_sessions", force: :cascade do |t|
    t.string "claude_session_id", null: false
    t.string "codebase_path", null: false
    t.datetime "created_at", null: false
    t.string "purpose", default: "refine", null: false
    t.string "status", default: "active", null: false
    t.bigint "task_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.bigint "workspace_id", null: false
    t.index ["task_id", "purpose", "status"], name: "index_chat_sessions_on_task_purpose_status"
    t.index ["task_id"], name: "index_chat_sessions_on_task_id"
    t.index ["user_id"], name: "index_chat_sessions_on_user_id"
    t.index ["workspace_id"], name: "index_chat_sessions_on_workspace_id"
  end

  create_table "clients", force: :cascade do |t|
    t.boolean "archived", default: false, null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.text "notes"
    t.datetime "updated_at", null: false
    t.bigint "workspace_id", null: false
    t.index ["workspace_id", "name"], name: "index_clients_on_workspace_id_and_name", unique: true
    t.index ["workspace_id"], name: "index_clients_on_workspace_id"
  end

  create_table "discord_reminder_pings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "discord_reminder_recipient_id", null: false
    t.datetime "sent_at", null: false
    t.datetime "updated_at", null: false
    t.index ["discord_reminder_recipient_id"], name: "index_discord_reminder_pings_on_recipient"
    t.index ["sent_at"], name: "index_discord_reminder_pings_on_sent_at"
  end

  create_table "discord_reminder_recipients", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.string "discord_user_id", null: false
    t.decimal "min_daily_hours", precision: 4, scale: 1, default: "4.0", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.bigint "workspace_id", null: false
    t.index ["user_id"], name: "index_discord_reminder_recipients_on_user_id"
    t.index ["workspace_id", "user_id"], name: "index_discord_reminder_recipients_on_workspace_id_and_user_id", unique: true
    t.index ["workspace_id"], name: "index_discord_reminder_recipients_on_workspace_id"
  end

  create_table "feedback_meetings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "creator_id", null: false
    t.bigint "employee_id", null: false
    t.text "notes"
    t.boolean "notes_visible", default: false, null: false
    t.datetime "scheduled_at", null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.bigint "workspace_id", null: false
    t.index ["creator_id"], name: "index_feedback_meetings_on_creator_id"
    t.index ["employee_id"], name: "index_feedback_meetings_on_employee_id"
    t.index ["workspace_id", "employee_id"], name: "index_feedback_meetings_on_workspace_id_and_employee_id"
    t.index ["workspace_id", "scheduled_at"], name: "index_feedback_meetings_on_workspace_id_and_scheduled_at"
    t.index ["workspace_id"], name: "index_feedback_meetings_on_workspace_id"
  end

  create_table "holiday_balance_entries", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.integer "days", null: false
    t.integer "entry_type", null: false
    t.bigint "holiday_request_id"
    t.text "note"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.bigint "workspace_id", null: false
    t.index ["created_by_id"], name: "index_holiday_balance_entries_on_created_by_id"
    t.index ["holiday_request_id"], name: "index_holiday_balance_entries_on_holiday_request_id"
    t.index ["user_id", "entry_type"], name: "index_holiday_balance_entries_on_user_id_and_entry_type"
    t.index ["user_id"], name: "index_holiday_balance_entries_on_user_id"
    t.index ["workspace_id", "user_id"], name: "index_holiday_balance_entries_on_workspace_id_and_user_id"
    t.index ["workspace_id"], name: "index_holiday_balance_entries_on_workspace_id"
  end

  create_table "holiday_requests", force: :cascade do |t|
    t.integer "business_days", null: false
    t.datetime "created_at", null: false
    t.date "end_date", null: false
    t.text "note"
    t.datetime "reviewed_at"
    t.bigint "reviewed_by_id"
    t.date "start_date", null: false
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.bigint "workspace_id", null: false
    t.index ["reviewed_by_id"], name: "index_holiday_requests_on_reviewed_by_id"
    t.index ["user_id", "start_date", "end_date"], name: "index_holiday_requests_on_user_id_and_start_date_and_end_date"
    t.index ["user_id"], name: "index_holiday_requests_on_user_id"
    t.index ["workspace_id", "status"], name: "index_holiday_requests_on_workspace_id_and_status"
    t.index ["workspace_id", "user_id"], name: "index_holiday_requests_on_workspace_id_and_user_id"
    t.index ["workspace_id"], name: "index_holiday_requests_on_workspace_id"
  end

  create_table "integrations", force: :cascade do |t|
    t.boolean "active", default: false, null: false
    t.jsonb "config", default: {}, null: false
    t.datetime "created_at", null: false
    t.string "provider", null: false
    t.datetime "updated_at", null: false
    t.bigint "workspace_id", null: false
    t.index ["workspace_id"], name: "index_integrations_on_workspace_id"
  end

  create_table "jira_board_column_statuses", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "jira_board_column_id", null: false
    t.string "jira_status_id", null: false
    t.string "jira_status_name", null: false
    t.datetime "updated_at", null: false
    t.index ["jira_board_column_id", "jira_status_id"], name: "idx_board_col_statuses_on_col_and_status", unique: true
    t.index ["jira_board_column_id"], name: "index_jira_board_column_statuses_on_jira_board_column_id"
  end

  create_table "jira_board_columns", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "jira_board_id", null: false
    t.string "name", null: false
    t.integer "position", null: false
    t.datetime "updated_at", null: false
    t.index ["jira_board_id", "position"], name: "index_jira_board_columns_on_jira_board_id_and_position", unique: true
    t.index ["jira_board_id"], name: "index_jira_board_columns_on_jira_board_id"
  end

  create_table "jira_boards", force: :cascade do |t|
    t.string "board_type", null: false
    t.datetime "created_at", null: false
    t.integer "jira_board_id", null: false
    t.string "name", null: false
    t.bigint "project_id", null: false
    t.datetime "updated_at", null: false
    t.index ["project_id", "jira_board_id"], name: "index_jira_boards_on_project_id_and_jira_board_id", unique: true
    t.index ["project_id"], name: "index_jira_boards_on_project_id"
  end

  create_table "jira_comments", force: :cascade do |t|
    t.string "author_email"
    t.string "author_name"
    t.text "body"
    t.text "body_adf"
    t.datetime "created_at", null: false
    t.string "jira_comment_id"
    t.datetime "jira_created_at"
    t.datetime "jira_updated_at"
    t.bigint "task_id", null: false
    t.datetime "updated_at", null: false
    t.index ["task_id", "jira_comment_id"], name: "index_jira_comments_on_task_id_and_jira_comment_id", unique: true
    t.index ["task_id"], name: "index_jira_comments_on_task_id"
  end

  create_table "jira_sprints", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "end_date"
    t.bigint "jira_board_id", null: false
    t.integer "jira_sprint_id", null: false
    t.string "name", null: false
    t.datetime "start_date"
    t.string "state", null: false
    t.datetime "updated_at", null: false
    t.index ["jira_board_id", "jira_sprint_id"], name: "index_jira_sprints_on_jira_board_id_and_jira_sprint_id", unique: true
    t.index ["jira_board_id"], name: "index_jira_sprints_on_jira_board_id"
  end

  create_table "pr_reviews", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "enqueued_sha"
    t.boolean "initial_done", default: false, null: false
    t.string "last_reviewed_sha"
    t.integer "pr_number", null: false
    t.datetime "reviewed_at"
    t.datetime "updated_at", null: false
    t.bigint "workspace_id", null: false
    t.index ["workspace_id", "pr_number"], name: "index_pr_reviews_on_workspace_id_and_pr_number", unique: true
    t.index ["workspace_id"], name: "index_pr_reviews_on_workspace_id"
  end

  create_table "project_memberships", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "hourly_rate_cents", default: 0, null: false
    t.bigint "project_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["project_id", "user_id"], name: "index_project_memberships_on_project_id_and_user_id", unique: true
    t.index ["project_id"], name: "index_project_memberships_on_project_id"
    t.index ["user_id"], name: "index_project_memberships_on_user_id"
  end

  create_table "projects", force: :cascade do |t|
    t.boolean "archived", default: false, null: false
    t.integer "budget_cents"
    t.decimal "budget_hours", precision: 10, scale: 2
    t.integer "budget_type", default: 0, null: false
    t.bigint "client_id"
    t.string "color", limit: 7, default: "#3B82F6", null: false
    t.text "context_info"
    t.datetime "created_at", null: false
    t.string "currency", limit: 3, default: "USD", null: false
    t.string "external_reference"
    t.string "external_type"
    t.text "features_summary"
    t.datetime "features_summary_updated_at"
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.bigint "workspace_id", null: false
    t.index ["client_id"], name: "index_projects_on_client_id"
    t.index ["workspace_id", "client_id"], name: "index_projects_on_workspace_id_and_client_id"
    t.index ["workspace_id", "name"], name: "index_projects_on_workspace_id_and_name"
    t.index ["workspace_id"], name: "index_projects_on_workspace_id"
  end

  create_table "rate_changes", force: :cascade do |t|
    t.datetime "changed_at", null: false
    t.bigint "changed_by_id"
    t.datetime "created_at", null: false
    t.integer "hourly_rate_cents", null: false
    t.integer "previous_rate_cents"
    t.bigint "project_membership_id", null: false
    t.datetime "updated_at", null: false
    t.index ["changed_by_id"], name: "index_rate_changes_on_changed_by_id"
    t.index ["project_membership_id"], name: "index_rate_changes_on_project_membership_id"
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
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

  create_table "tags", force: :cascade do |t|
    t.string "color", limit: 7, default: "#6B7280", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.bigint "workspace_id", null: false
    t.index ["workspace_id", "name"], name: "index_tags_on_workspace_id_and_name", unique: true
    t.index ["workspace_id"], name: "index_tags_on_workspace_id"
  end

  create_table "task_drafts", force: :cascade do |t|
    t.text "content"
    t.datetime "created_at", null: false
    t.string "source"
    t.bigint "task_id", null: false
    t.datetime "updated_at", null: false
    t.index ["task_id", "created_at"], name: "index_task_drafts_on_task_id_and_created_at"
    t.index ["task_id"], name: "index_task_drafts_on_task_id"
  end

  create_table "tasks", force: :cascade do |t|
    t.string "assignee_email"
    t.string "assignee_name"
    t.datetime "created_at", null: false
    t.text "description"
    t.text "description_adf"
    t.string "external_reference"
    t.string "external_type"
    t.string "external_url"
    t.string "issue_type"
    t.string "jira_status_name"
    t.datetime "jira_updated_at"
    t.text "labels"
    t.string "name", null: false
    t.string "priority"
    t.bigint "project_id", null: false
    t.string "reporter_email"
    t.string "reporter_name"
    t.integer "sprint_id"
    t.string "sprint_name"
    t.integer "status", default: 0, null: false
    t.integer "time_estimate_seconds"
    t.datetime "updated_at", null: false
    t.index ["project_id", "external_type", "external_reference"], name: "index_tasks_on_project_external_ref", unique: true, where: "(external_type IS NOT NULL)"
    t.index ["project_id", "jira_updated_at"], name: "index_tasks_on_project_id_and_jira_updated_at"
    t.index ["project_id", "name"], name: "index_tasks_on_project_id_and_name", unique: true
    t.index ["project_id"], name: "index_tasks_on_project_id"
  end

  create_table "time_entries", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "description"
    t.integer "duration_seconds", default: 0, null: false
    t.integer "hourly_rate_cents"
    t.bigint "project_id", null: false
    t.datetime "started_at", null: false
    t.datetime "stopped_at"
    t.bigint "task_id"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.bigint "workspace_id", null: false
    t.index ["project_id"], name: "index_time_entries_on_project_id"
    t.index ["task_id"], name: "index_time_entries_on_task_id"
    t.index ["user_id", "stopped_at"], name: "index_time_entries_on_user_id_and_stopped_at"
    t.index ["user_id"], name: "index_time_entries_on_user_id"
    t.index ["workspace_id", "started_at"], name: "index_time_entries_on_workspace_id_and_started_at"
    t.index ["workspace_id", "user_id", "started_at"], name: "index_time_entries_on_workspace_id_and_user_id_and_started_at"
    t.index ["workspace_id"], name: "index_time_entries_on_workspace_id"
  end

  create_table "time_entry_tags", force: :cascade do |t|
    t.bigint "tag_id", null: false
    t.bigint "time_entry_id", null: false
    t.index ["tag_id"], name: "index_time_entry_tags_on_tag_id"
    t.index ["time_entry_id", "tag_id"], name: "index_time_entry_tags_on_time_entry_id_and_tag_id", unique: true
    t.index ["time_entry_id"], name: "index_time_entry_tags_on_time_entry_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email_address", null: false
    t.string "name", null: false
    t.string "password_digest", null: false
    t.string "timezone", default: "UTC", null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  create_table "workspace_memberships", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "role", default: 0, null: false
    t.boolean "time_hr_access", default: true, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.boolean "workshop_access", default: false, null: false
    t.bigint "workspace_id", null: false
    t.index ["user_id", "workspace_id"], name: "index_workspace_memberships_on_user_id_and_workspace_id", unique: true
    t.index ["user_id"], name: "index_workspace_memberships_on_user_id"
    t.index ["workspace_id"], name: "index_workspace_memberships_on_workspace_id"
  end

  create_table "workspaces", force: :cascade do |t|
    t.boolean "clients_enabled", default: false, null: false
    t.datetime "created_at", null: false
    t.string "discord_channel_id"
    t.string "discord_user_token"
    t.string "github_repo"
    t.datetime "github_status_checked_at"
    t.string "github_status_error"
    t.boolean "github_status_ok"
    t.string "github_token"
    t.string "jira_ai_actions_field_id"
    t.string "name", null: false
    t.boolean "pr_review_enabled", default: false, null: false
    t.datetime "updated_at", null: false
    t.boolean "workshop_enabled", default: false, null: false
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "briefs", "chat_sessions"
  add_foreign_key "briefs", "tasks"
  add_foreign_key "briefs", "workspaces"
  add_foreign_key "chat_messages", "chat_sessions"
  add_foreign_key "chat_messages", "users"
  add_foreign_key "chat_sessions", "tasks"
  add_foreign_key "chat_sessions", "users"
  add_foreign_key "chat_sessions", "workspaces"
  add_foreign_key "clients", "workspaces"
  add_foreign_key "discord_reminder_pings", "discord_reminder_recipients"
  add_foreign_key "discord_reminder_recipients", "users"
  add_foreign_key "discord_reminder_recipients", "workspaces"
  add_foreign_key "feedback_meetings", "users", column: "creator_id"
  add_foreign_key "feedback_meetings", "users", column: "employee_id"
  add_foreign_key "feedback_meetings", "workspaces"
  add_foreign_key "holiday_balance_entries", "holiday_requests"
  add_foreign_key "holiday_balance_entries", "users"
  add_foreign_key "holiday_balance_entries", "users", column: "created_by_id"
  add_foreign_key "holiday_balance_entries", "workspaces"
  add_foreign_key "holiday_requests", "users"
  add_foreign_key "holiday_requests", "users", column: "reviewed_by_id"
  add_foreign_key "holiday_requests", "workspaces"
  add_foreign_key "integrations", "workspaces"
  add_foreign_key "jira_board_column_statuses", "jira_board_columns"
  add_foreign_key "jira_board_columns", "jira_boards"
  add_foreign_key "jira_boards", "projects"
  add_foreign_key "jira_comments", "tasks"
  add_foreign_key "jira_sprints", "jira_boards"
  add_foreign_key "pr_reviews", "workspaces"
  add_foreign_key "project_memberships", "projects"
  add_foreign_key "project_memberships", "users"
  add_foreign_key "projects", "clients"
  add_foreign_key "projects", "workspaces"
  add_foreign_key "rate_changes", "project_memberships"
  add_foreign_key "rate_changes", "users", column: "changed_by_id"
  add_foreign_key "sessions", "users"
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "tags", "workspaces"
  add_foreign_key "task_drafts", "tasks"
  add_foreign_key "tasks", "projects"
  add_foreign_key "time_entries", "projects"
  add_foreign_key "time_entries", "tasks"
  add_foreign_key "time_entries", "users"
  add_foreign_key "time_entries", "workspaces"
  add_foreign_key "time_entry_tags", "tags"
  add_foreign_key "time_entry_tags", "time_entries"
  add_foreign_key "workspace_memberships", "users"
  add_foreign_key "workspace_memberships", "workspaces"
end
