# frozen_string_literal: true

class CreateStatusReports < ActiveRecord::Migration[8.1]
  def change
    create_table :status_reports do |t|
      t.string :name, null: false
      t.integer :complete_count, null: false, default: 0
      t.integer :error_count, null: false, default: 0
      t.timestamps
    end

    add_index :status_reports, :name, unique: true
  end
end
