class CreateAuditLogs < ActiveRecord::Migration[8.0]
  def change
    create_table :audit_logs do |t|
      t.string :idpk, null: false
      t.string :event_type, null: false
      t.string :reason, null: false
      t.jsonb :raw_payload, null: false, default: {}

      t.datetime :created_at, null: false
    end
  end
end