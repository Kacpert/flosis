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

ActiveRecord::Schema[8.1].define(version: 2026_03_15_213106) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

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

  create_table "integrations", force: :cascade do |t|
    t.boolean "active", default: false, null: false
    t.jsonb "config", default: {}, null: false
    t.datetime "created_at", null: false
    t.string "provider", null: false
    t.datetime "updated_at", null: false
    t.bigint "workspace_id", null: false
    t.index ["workspace_id"], name: "index_integrations_on_workspace_id"
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
    t.boolean "billable", default: true, null: false
    t.integer "budget_cents"
    t.decimal "budget_hours", precision: 10, scale: 2
    t.integer "budget_type", default: 0, null: false
    t.bigint "client_id"
    t.string "color", limit: 7, default: "#3B82F6", null: false
    t.datetime "created_at", null: false
    t.string "external_reference"
    t.string "external_type"
    t.integer "hourly_rate_cents"
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

  create_table "tasks", force: :cascade do |t|
    t.string "assignee_email"
    t.boolean "billable"
    t.datetime "created_at", null: false
    t.string "external_reference"
    t.string "external_type"
    t.string "external_url"
    t.integer "hourly_rate_cents"
    t.string "jira_status_name"
    t.string "name", null: false
    t.bigint "project_id", null: false
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["project_id", "external_type", "external_reference"], name: "index_tasks_on_project_external_ref", unique: true, where: "(external_type IS NOT NULL)"
    t.index ["project_id", "name"], name: "index_tasks_on_project_id_and_name", unique: true
    t.index ["project_id"], name: "index_tasks_on_project_id"
  end

  create_table "time_entries", force: :cascade do |t|
    t.boolean "billable", default: true, null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.integer "duration_seconds", default: 0, null: false
    t.integer "hourly_rate_cents"
    t.bigint "project_id"
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
    t.integer "default_hourly_rate_cents", default: 0
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
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.bigint "workspace_id", null: false
    t.index ["user_id", "workspace_id"], name: "index_workspace_memberships_on_user_id_and_workspace_id", unique: true
    t.index ["user_id"], name: "index_workspace_memberships_on_user_id"
    t.index ["workspace_id"], name: "index_workspace_memberships_on_workspace_id"
  end

  create_table "workspaces", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "default_currency", limit: 3, default: "USD", null: false
    t.integer "default_hourly_rate_cents", default: 0
    t.string "name", null: false
    t.integer "time_format", default: 0, null: false
    t.datetime "updated_at", null: false
    t.integer "week_start", default: 1, null: false
  end

  add_foreign_key "clients", "workspaces"
  add_foreign_key "integrations", "workspaces"
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
