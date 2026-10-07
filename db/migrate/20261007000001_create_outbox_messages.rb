class CreateOutboxMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :outbox_messages do |t|
      t.string :msg_id, null: false
      t.string :idpk, null: false
      t.string :message_type, null: false
      t.jsonb :payload, null: false, default: {}
      t.string :status, null: false, default: "pending"
      t.integer :attempts, null: false, default: 0
      t.string :error
      t.datetime :sent_at
      t.timestamps
    end

    add_index :outbox_messages, :msg_id, unique: true
    add_index :outbox_messages, :status
  end
end
