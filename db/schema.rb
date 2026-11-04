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

ActiveRecord::Schema[8.1].define(version: 2026_11_04_120000) do
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

  create_table "alert_rule_prompt_versions", force: :cascade do |t|
    t.bigint "alert_rule_id", null: false
    t.datetime "created_at", null: false
    t.text "prompt", null: false
    t.index ["alert_rule_id", "created_at"], name: "idx_on_alert_rule_id_created_at_5311c4716f"
  end

  create_table "alert_rules", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.text "ai_issues"
    t.datetime "created_at", null: false
    t.bigint "discord_webhook_id"
    t.string "frequency", default: "daily", null: false
    t.integer "interval_hours", default: 4, null: false
    t.datetime "last_run_at"
    t.text "memory"
    t.string "name", null: false
    t.boolean "notify_enabled", default: true, null: false
    t.integer "position"
    t.bigint "project_id", null: false
    t.text "prompt", null: false
    t.string "run_at_time"
    t.string "schedule_days", default: "Mon,Tue,Wed,Thu,Fri,Sat,Sun", null: false
    t.string "schedule_mode", default: "daily", null: false
    t.datetime "updated_at", null: false
    t.boolean "window_enabled", default: false, null: false
    t.string "window_from", default: "09:00", null: false
    t.string "window_to", default: "18:00", null: false
    t.bigint "workspace_id", null: false
    t.index ["discord_webhook_id"], name: "index_alert_rules_on_discord_webhook_id"
    t.index ["project_id"], name: "index_alert_rules_on_project_id"
    t.index ["workspace_id"], name: "index_alert_rules_on_workspace_id"
  end

  create_table "alert_runs", force: :cascade do |t|
    t.bigint "alert_rule_id", null: false
    t.datetime "created_at", null: false
    t.text "detail"
    t.boolean "fired", default: false, null: false
    t.datetime "ran_at", null: false
    t.string "status", default: "ok", null: false
    t.string "summary"
    t.datetime "updated_at", null: false
    t.index ["alert_rule_id"], name: "index_alert_runs_on_alert_rule_id"
  end

  create_table "api_tokens", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.datetime "last_used_at"
    t.string "name", null: false
    t.datetime "revoked_at"
    t.string "scopes", null: false
    t.string "token_digest", null: false
    t.string "token_hint", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.bigint "workspace_id", null: false
    t.index ["token_digest"], name: "index_api_tokens_on_token_digest", unique: true
    t.index ["user_id"], name: "index_api_tokens_on_user_id"
    t.index ["workspace_id"], name: "index_api_tokens_on_workspace_id"
  end

  create_table "briefs", force: :cascade do |t|
    t.datetime "briefed_at"
    t.bigint "chat_session_id"
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.boolean "current", default: false, null: false
    t.datetime "edited_at"
    t.string "origin", default: "ai", null: false
    t.string "status", default: "draft", null: false
    t.bigint "task_id", null: false
    t.datetime "updated_at", null: false
    t.integer "version", default: 1, null: false
    t.bigint "workspace_id", null: false
    t.index ["chat_session_id"], name: "index_briefs_on_chat_session_id"
    t.index ["task_id", "current"], name: "index_briefs_on_task_id_and_current"
    t.index ["task_id", "version"], name: "index_briefs_on_task_id_and_version", unique: true
    t.index ["task_id"], name: "index_briefs_on_task_id"
    t.index ["workspace_id"], name: "index_briefs_on_workspace_id"
  end

  create_table "bug_attributions", force: :cascade do |t|
    t.datetime "analyzed_at"
    t.string "author_email"
    t.string "author_name"
    t.string "confidence"
    t.datetime "created_at", null: false
    t.string "jira_key", null: false
    t.string "origin_kind"
    t.bigint "project_id", null: false
    t.text "reasoning"
    t.string "status", default: "pending", null: false
    t.bigint "task_id"
    t.datetime "updated_at", null: false
    t.index ["project_id", "jira_key"], name: "index_bug_attributions_on_project_id_and_jira_key", unique: true
    t.index ["project_id"], name: "index_bug_attributions_on_project_id"
    t.index ["task_id"], name: "index_bug_attributions_on_task_id"
  end

  create_table "chat_messages", force: :cascade do |t|
    t.bigint "chat_session_id", null: false
    t.text "content", null: false
    t.datetime "created_at", null: false
    t.json "data"
    t.string "kind"
    t.string "role", null: false
    t.text "thinking"
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["chat_session_id"], name: "index_chat_messages_on_chat_session_id"
    t.index ["user_id"], name: "index_chat_messages_on_user_id"
  end

  create_table "chat_sessions", force: :cascade do |t|
    t.string "claude_session_id", null: false
    t.string "codebase_path", null: false
    t.datetime "created_at", null: false
    t.bigint "design_setup_id"
    t.bigint "project_id"
    t.string "purpose", default: "refine", null: false
    t.string "status", default: "active", null: false
    t.bigint "task_id"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.bigint "workspace_id", null: false
    t.index ["design_setup_id"], name: "index_chat_sessions_on_design_setup_id"
    t.index ["project_id"], name: "index_chat_sessions_on_project_id"
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

  create_table "delivered_issues", force: :cascade do |t|
    t.decimal "ai_estimate_points", precision: 5, scale: 1
    t.string "assignee_email"
    t.string "assignee_name"
    t.datetime "created_at", null: false
    t.text "description"
    t.string "issue_type"
    t.datetime "jira_created_at"
    t.string "jira_key", null: false
    t.bigint "project_id", null: false
    t.string "reporter_email"
    t.string "reporter_name"
    t.datetime "resolved_at"
    t.decimal "story_points", precision: 5, scale: 1
    t.string "title"
    t.datetime "updated_at", null: false
    t.index ["project_id", "jira_key"], name: "index_delivered_issues_on_project_id_and_jira_key", unique: true
    t.index ["project_id", "resolved_at"], name: "index_delivered_issues_on_project_id_and_resolved_at"
    t.index ["project_id"], name: "index_delivered_issues_on_project_id"
  end

  create_table "design_approvals", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "design_sha", null: false
    t.text "jira_links_error"
    t.datetime "jira_links_synced_at"
    t.string "master_sha", null: false
    t.integer "number", null: false
    t.string "tag", null: false
    t.bigint "task_id", null: false
    t.bigint "user_id", null: false
    t.index ["task_id", "number"], name: "index_design_approvals_on_task_id_and_number", unique: true
    t.index ["user_id"], name: "index_design_approvals_on_user_id"
  end

  create_table "design_import_views", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "design_setup_id", null: false
    t.datetime "seen_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["design_setup_id", "user_id"], name: "index_design_import_views_on_design_setup_id_and_user_id", unique: true
    t.index ["user_id"], name: "index_design_import_views_on_user_id"
  end

  create_table "design_merges", force: :cascade do |t|
    t.string "branch", null: false
    t.integer "commits", default: 1, null: false
    t.datetime "created_at", null: false
    t.bigint "design_thread_id"
    t.string "how", null: false
    t.datetime "merged_at", null: false
    t.bigint "project_id", null: false
    t.json "screens"
    t.string "sha", null: false
    t.text "summary"
    t.bigint "task_id"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.json "what_changed"
    t.index ["design_thread_id"], name: "index_design_merges_on_design_thread_id"
    t.index ["project_id", "merged_at"], name: "index_design_merges_on_project_id_and_merged_at"
    t.index ["project_id"], name: "index_design_merges_on_project_id"
    t.index ["task_id"], name: "index_design_merges_on_task_id"
    t.index ["user_id"], name: "index_design_merges_on_user_id"
  end

  create_table "design_requests", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "delivered_at"
    t.bigint "designer_id", null: false
    t.json "links"
    t.text "note"
    t.bigint "requester_id", null: false
    t.string "status", default: "requested", null: false
    t.bigint "task_id", null: false
    t.datetime "updated_at", null: false
    t.index ["designer_id"], name: "index_design_requests_on_designer_id"
    t.index ["requester_id"], name: "index_design_requests_on_requester_id"
    t.index ["task_id"], name: "index_design_requests_on_task_id", unique: true
  end

  create_table "design_setup_features", force: :cascade do |t|
    t.integer "attempts", default: 0, null: false
    t.string "branch"
    t.text "brief"
    t.text "code_changes"
    t.integer "components_new", default: 0, null: false
    t.integer "components_reused", default: 0, null: false
    t.json "contexts"
    t.datetime "created_at", null: false
    t.bigint "design_setup_id", null: false
    t.bigint "design_turn_id"
    t.text "error"
    t.datetime "finished_at"
    t.string "key", null: false
    t.string "name", null: false
    t.json "notes"
    t.integer "position", null: false
    t.text "question"
    t.datetime "queued_at"
    t.text "reply"
    t.datetime "resets_at"
    t.json "review"
    t.json "screens"
    t.string "source", default: "map", null: false
    t.string "stage"
    t.datetime "started_at"
    t.string "status", default: "todo", null: false
    t.datetime "updated_at", null: false
    t.index ["design_setup_id", "key"], name: "index_design_setup_features_on_design_setup_id_and_key", unique: true
    t.index ["design_setup_id", "position"], name: "index_design_setup_features_on_design_setup_id_and_position", unique: true
    t.index ["design_turn_id"], name: "index_design_setup_features_on_design_turn_id"
  end

  create_table "design_setup_roles", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "login_url", null: false
    t.string "name", null: false
    t.text "notes"
    t.text "password", null: false
    t.integer "position", default: 0, null: false
    t.bigint "project_id", null: false
    t.datetime "updated_at", null: false
    t.string "username", null: false
    t.index ["project_id"], name: "index_design_setup_roles_on_project_id"
  end

  create_table "design_setups", force: :cascade do |t|
    t.json "app_commits"
    t.datetime "approved_at"
    t.string "crawl_dir"
    t.text "crawl_error"
    t.datetime "crawl_requested_at"
    t.datetime "crawled_at"
    t.datetime "created_at", null: false
    t.bigint "design_thread_id"
    t.text "error"
    t.datetime "finished_at"
    t.string "kind", default: "first", null: false
    t.json "notes"
    t.datetime "notified_at"
    t.integer "pages"
    t.datetime "paused_until"
    t.string "phase", default: "design_system", null: false
    t.bigint "project_id", null: false
    t.datetime "settled_at"
    t.bigint "since_setup_id"
    t.bigint "started_by_id"
    t.string "status", default: "active", null: false
    t.integer "step", default: 0, null: false
    t.json "step_seconds"
    t.datetime "step_started_at"
    t.datetime "unit_deadline_at"
    t.string "unit_job_id"
    t.datetime "updated_at", null: false
    t.index ["design_thread_id"], name: "index_design_setups_on_design_thread_id"
    t.index ["project_id"], name: "index_design_setups_on_project_id"
    t.index ["started_by_id"], name: "index_design_setups_on_started_by_id"
  end

  create_table "design_threads", force: :cascade do |t|
    t.bigint "author_id"
    t.string "base_sha"
    t.string "branch"
    t.bigint "chat_session_id"
    t.datetime "created_at", null: false
    t.text "described_text"
    t.string "described_version"
    t.string "focus_context"
    t.string "focus_screen"
    t.datetime "merged_at"
    t.string "merged_sha"
    t.bigint "project_id", null: false
    t.string "status", default: "open", null: false
    t.bigint "task_id"
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.index ["author_id"], name: "index_design_threads_on_author_id"
    t.index ["chat_session_id"], name: "index_design_threads_on_chat_session_id"
    t.index ["project_id", "branch"], name: "index_design_threads_on_project_id_and_branch", unique: true
    t.index ["project_id"], name: "index_design_threads_on_project_id"
    t.index ["task_id"], name: "index_design_threads_on_task_id", unique: true
  end

  create_table "design_turns", force: :cascade do |t|
    t.bigint "chat_message_id", null: false
    t.bigint "chat_session_id", null: false
    t.string "commit_sha"
    t.datetime "created_at", null: false
    t.text "error"
    t.datetime "finished_at"
    t.string "kind", default: "design", null: false
    t.json "library_version_ids"
    t.datetime "started_at"
    t.string "status", default: "queued", null: false
    t.datetime "updated_at", null: false
    t.index ["chat_message_id"], name: "index_design_turns_on_chat_message_id"
    t.index ["chat_session_id", "status"], name: "index_design_turns_on_chat_session_id_and_status"
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

  create_table "discord_webhooks", force: :cascade do |t|
    t.string "channel_name", null: false
    t.datetime "created_at", null: false
    t.bigint "project_id"
    t.datetime "updated_at", null: false
    t.string "url", null: false
    t.bigint "workspace_id", null: false
    t.index ["project_id"], name: "index_discord_webhooks_on_project_id"
    t.index ["workspace_id"], name: "index_discord_webhooks_on_workspace_id"
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

  create_table "library_entries", force: :cascade do |t|
    t.boolean "active", default: true, null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.string "key", null: false
    t.string "kind", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_library_entries_on_key", unique: true
  end

  create_table "library_entry_versions", force: :cascade do |t|
    t.text "body", null: false
    t.datetime "created_at", null: false
    t.bigint "created_by_id"
    t.bigint "library_entry_id", null: false
    t.integer "number", null: false
    t.index ["created_by_id"], name: "index_library_entry_versions_on_created_by_id"
    t.index ["library_entry_id", "number"], name: "index_library_entry_versions_on_library_entry_id_and_number", unique: true
  end

  create_table "pr_reviews", force: :cascade do |t|
    t.string "attempt_sha"
    t.integer "attempts", default: 0, null: false
    t.integer "comment_count"
    t.datetime "created_at", null: false
    t.string "enqueued_sha"
    t.boolean "initial_done", default: false, null: false
    t.string "last_error"
    t.string "last_reviewed_sha"
    t.datetime "next_attempt_at"
    t.string "outcome", default: "pending", null: false
    t.string "pr_author"
    t.string "pr_branch"
    t.integer "pr_number", null: false
    t.string "pr_title"
    t.string "pr_url"
    t.bigint "project_id"
    t.datetime "reviewed_at"
    t.datetime "updated_at", null: false
    t.bigint "workspace_id", null: false
    t.index ["project_id", "pr_number"], name: "index_pr_reviews_on_project_id_and_pr_number", unique: true
    t.index ["project_id"], name: "index_pr_reviews_on_project_id"
    t.index ["workspace_id"], name: "index_pr_reviews_on_workspace_id"
  end

  create_table "project_memberships", force: :cascade do |t|
    t.boolean "automations", default: true, null: false
    t.boolean "briefing_config", default: false, null: false
    t.boolean "configuration", default: false, null: false
    t.datetime "created_at", null: false
    t.boolean "designs", default: false, null: false
    t.integer "hourly_rate_cents", default: 0, null: false
    t.boolean "pricing", default: false, null: false
    t.bigint "project_id", null: false
    t.boolean "reporting", default: true, null: false
    t.boolean "tasks", default: true, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["project_id", "user_id"], name: "index_project_memberships_on_project_id_and_user_id", unique: true
    t.index ["project_id"], name: "index_project_memberships_on_project_id"
    t.index ["user_id"], name: "index_project_memberships_on_user_id"
  end

  create_table "projects", force: :cascade do |t|
    t.text "anthropic_api_key"
    t.boolean "archived", default: false, null: false
    t.text "briefing_personas"
    t.integer "budget_cents"
    t.decimal "budget_hours", precision: 10, scale: 2
    t.integer "budget_type", default: 0, null: false
    t.bigint "client_id"
    t.string "color", limit: 7, default: "#3B82F6", null: false
    t.text "context_info"
    t.datetime "created_at", null: false
    t.string "currency", limit: 3, default: "USD", null: false
    t.json "design_app_repos"
    t.string "design_app_url"
    t.string "design_base_kit", default: "tailwind4", null: false
    t.json "design_figma_urls"
    t.string "design_preview_token"
    t.string "design_repo"
    t.text "design_repo_error"
    t.string "design_repo_status"
    t.text "design_repo_token"
    t.string "design_style_pack_key"
    t.boolean "designs_enabled", default: false, null: false
    t.string "designs_framework", default: "html", null: false
    t.string "designs_framework_version"
    t.string "designs_ui_system", default: "tailwind", null: false
    t.string "designs_ui_version", default: "4"
    t.json "estimation_field_names"
    t.string "estimation_status_trigger", default: "Ready for dev"
    t.string "estimation_trigger", default: "manual", null: false
    t.string "external_reference"
    t.string "external_type"
    t.text "features_summary"
    t.datetime "features_summary_updated_at"
    t.boolean "figma_read_enabled", default: false, null: false
    t.datetime "figma_status_checked_at"
    t.string "figma_status_error"
    t.boolean "figma_status_ok"
    t.text "figma_token"
    t.string "github_branch"
    t.string "github_repo"
    t.datetime "github_status_checked_at"
    t.string "github_status_error"
    t.boolean "github_status_ok"
    t.text "github_token"
    t.string "jira_ai_actions_field_id"
    t.string "jira_ai_estimation_field_id"
    t.text "jira_api_token"
    t.string "jira_email"
    t.string "jira_site"
    t.datetime "jira_status_checked_at"
    t.string "jira_status_error"
    t.boolean "jira_status_ok"
    t.string "jira_story_points_field_id"
    t.datetime "mcp_synced_at"
    t.string "name", null: false
    t.integer "pr_poll_minutes", default: 7, null: false
    t.datetime "pr_polled_at"
    t.boolean "pr_review_enabled", default: false, null: false
    t.text "pr_review_prompt"
    t.string "repo_checkout_error"
    t.string "repo_checkout_status"
    t.boolean "show_in_workshop", default: false, null: false
    t.string "team"
    t.datetime "updated_at", null: false
    t.string "workspace_dir"
    t.bigint "workspace_id", null: false
    t.index ["client_id"], name: "index_projects_on_client_id"
    t.index ["design_preview_token"], name: "index_projects_on_design_preview_token", unique: true
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
    t.boolean "current", default: false, null: false
    t.datetime "edited_at"
    t.string "origin", default: "ai", null: false
    t.datetime "pushed_at"
    t.string "source"
    t.bigint "task_id", null: false
    t.datetime "updated_at", null: false
    t.integer "version"
    t.index ["task_id", "created_at"], name: "index_task_drafts_on_task_id_and_created_at"
    t.index ["task_id", "source", "current"], name: "index_task_drafts_on_task_id_and_source_and_current"
    t.index ["task_id"], name: "index_task_drafts_on_task_id"
  end

  create_table "tasks", force: :cascade do |t|
    t.decimal "ai_estimate_points", precision: 5, scale: 1
    t.datetime "ai_estimated_at"
    t.string "assignee_email"
    t.string "assignee_name"
    t.datetime "brief_saved_locally_at"
    t.datetime "created_at", null: false
    t.text "description"
    t.text "description_adf"
    t.string "designs_described_sha"
    t.datetime "detail_saved_locally_at"
    t.string "external_reference"
    t.string "external_type"
    t.string "external_url"
    t.boolean "in_pipeline", default: false, null: false
    t.string "issue_type"
    t.datetime "jira_created_at"
    t.string "jira_status_name"
    t.datetime "jira_updated_at"
    t.text "labels"
    t.string "name", null: false
    t.bigint "pipeline_author_id"
    t.datetime "pipeline_entered_at"
    t.string "priority"
    t.bigint "project_id", null: false
    t.string "reporter_email"
    t.string "reporter_name"
    t.integer "sprint_id"
    t.string "sprint_name"
    t.integer "status", default: 0, null: false
    t.decimal "story_points", precision: 5, scale: 1
    t.integer "time_estimate_seconds"
    t.datetime "updated_at", null: false
    t.string "workshop_stage", default: "new", null: false
    t.index ["pipeline_author_id"], name: "index_tasks_on_pipeline_author_id"
    t.index ["project_id", "external_type", "external_reference"], name: "index_tasks_on_project_external_ref", unique: true, where: "(external_type IS NOT NULL)"
    t.index ["project_id", "in_pipeline", "workshop_stage"], name: "index_tasks_on_project_id_and_in_pipeline_and_workshop_stage"
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
    t.boolean "flosis_staff", default: false, null: false
    t.string "name", null: false
    t.string "password_digest", null: false
    t.string "timezone", default: "UTC", null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
  end

  create_table "workspace_memberships", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "time_hr_access", default: true, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.boolean "workspace_admin", default: false, null: false
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
    t.boolean "hr_access", default: false, null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
    t.boolean "workshop_enabled", default: false, null: false
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "alert_rules", "discord_webhooks"
  add_foreign_key "alert_rules", "projects"
  add_foreign_key "alert_rules", "workspaces"
  add_foreign_key "alert_runs", "alert_rules"
  add_foreign_key "api_tokens", "users"
  add_foreign_key "api_tokens", "workspaces"
  add_foreign_key "briefs", "chat_sessions"
  add_foreign_key "briefs", "tasks"
  add_foreign_key "briefs", "workspaces"
  add_foreign_key "bug_attributions", "projects"
  add_foreign_key "bug_attributions", "tasks"
  add_foreign_key "chat_messages", "chat_sessions"
  add_foreign_key "chat_messages", "users"
  add_foreign_key "chat_sessions", "design_setups", on_delete: :nullify
  add_foreign_key "chat_sessions", "projects"
  add_foreign_key "chat_sessions", "tasks"
  add_foreign_key "chat_sessions", "users"
  add_foreign_key "chat_sessions", "workspaces"
  add_foreign_key "clients", "workspaces"
  add_foreign_key "delivered_issues", "projects"
  add_foreign_key "design_approvals", "tasks"
  add_foreign_key "design_approvals", "users"
  add_foreign_key "design_import_views", "design_setups", on_delete: :cascade
  add_foreign_key "design_import_views", "users", on_delete: :cascade
  add_foreign_key "design_merges", "design_threads", on_delete: :nullify
  add_foreign_key "design_merges", "projects"
  add_foreign_key "design_merges", "tasks", on_delete: :nullify
  add_foreign_key "design_merges", "users", on_delete: :nullify
  add_foreign_key "design_requests", "tasks"
  add_foreign_key "design_requests", "users", column: "designer_id"
  add_foreign_key "design_requests", "users", column: "requester_id"
  add_foreign_key "design_setup_features", "design_setups"
  add_foreign_key "design_setup_features", "design_turns", on_delete: :nullify
  add_foreign_key "design_setup_roles", "projects"
  add_foreign_key "design_setups", "design_threads", on_delete: :nullify
  add_foreign_key "design_setups", "projects"
  add_foreign_key "design_setups", "users", column: "started_by_id", on_delete: :nullify
  add_foreign_key "design_threads", "chat_sessions", on_delete: :nullify
  add_foreign_key "design_threads", "projects"
  add_foreign_key "design_threads", "tasks", on_delete: :nullify
  add_foreign_key "design_threads", "users", column: "author_id", on_delete: :nullify
  add_foreign_key "design_turns", "chat_messages"
  add_foreign_key "design_turns", "chat_sessions"
  add_foreign_key "discord_reminder_pings", "discord_reminder_recipients"
  add_foreign_key "discord_reminder_recipients", "users"
  add_foreign_key "discord_reminder_recipients", "workspaces"
  add_foreign_key "discord_webhooks", "workspaces"
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
  add_foreign_key "library_entry_versions", "library_entries"
  add_foreign_key "library_entry_versions", "users", column: "created_by_id", on_delete: :nullify
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
  add_foreign_key "tasks", "users", column: "pipeline_author_id"
  add_foreign_key "time_entries", "projects"
  add_foreign_key "time_entries", "tasks"
  add_foreign_key "time_entries", "users"
  add_foreign_key "time_entries", "workspaces"
  add_foreign_key "time_entry_tags", "tags"
  add_foreign_key "time_entry_tags", "time_entries"
  add_foreign_key "workspace_memberships", "users"
  add_foreign_key "workspace_memberships", "workspaces"
end
