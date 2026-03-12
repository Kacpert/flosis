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

ActiveRecord::Schema[8.1].define(version: 2026_03_12_122806) do
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

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
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
    t.boolean "billable"
    t.datetime "created_at", null: false
    t.string "external_reference"
    t.string "external_type"
    t.string "external_url"
    t.integer "hourly_rate_cents"
    t.string "name", null: false
    t.bigint "project_id", null: false
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
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
  add_foreign_key "projects", "clients"
  add_foreign_key "projects", "workspaces"
  add_foreign_key "sessions", "users"
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
