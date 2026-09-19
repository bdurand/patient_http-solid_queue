# frozen_string_literal: true

class CreatePatientHttpSolidQueueTables < ActiveRecord::Migration[7.1]
  def change
    create_table :patient_http_solid_queue_inflight_requests do |t|
      t.string :task_id, null: false, index: {unique: true}
      t.string :process_id, null: false, index: true
      t.text :job_payload, null: false
      t.datetime :heartbeat_at, precision: 6, null: false, index: true
      t.datetime :created_at, precision: 6, null: false
    end

    create_table :patient_http_solid_queue_processes do |t|
      t.string :process_id, null: false, index: {unique: true}
      t.integer :max_connections, null: false
      t.datetime :last_seen_at, precision: 6, null: false
    end

    create_table :patient_http_solid_queue_gc_locks do |t|
      t.string :lock_name, null: false, index: {unique: true}
      t.string :lock_holder
      t.datetime :acquired_at, precision: 6
      t.datetime :expires_at, precision: 6
      t.datetime :last_gc_at, precision: 6
    end
  end
end
