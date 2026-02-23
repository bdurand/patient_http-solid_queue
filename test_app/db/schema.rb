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

ActiveRecord::Schema[8.1].define(version: 2026_02_16_000000) do
  create_table "patient_http_solid_queue_gc_locks", force: :cascade do |t|
    t.datetime "acquired_at"
    t.datetime "expires_at"
    t.datetime "last_gc_at"
    t.string "lock_holder"
    t.string "lock_name", null: false
    t.index ["lock_name"], name: "index_patient_http_solid_queue_gc_locks_on_lock_name", unique: true
  end

  create_table "patient_http_solid_queue_inflight_requests", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "heartbeat_at", null: false
    t.text "job_payload", null: false
    t.string "process_id", null: false
    t.string "task_id", null: false
    t.index ["heartbeat_at"], name: "idx_on_heartbeat_at_833687ac7f"
    t.index ["process_id"], name: "index_patient_http_solid_queue_inflight_requests_on_process_id"
    t.index ["task_id"], name: "index_patient_http_solid_queue_inflight_requests_on_task_id", unique: true
  end

  create_table "patient_http_solid_queue_processes", force: :cascade do |t|
    t.datetime "last_seen_at", null: false
    t.integer "max_connections", null: false
    t.string "process_id", null: false
    t.index ["process_id"], name: "index_patient_http_solid_queue_processes_on_process_id", unique: true
  end
end
