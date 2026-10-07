class CreateProcessedMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :processed_messages do |t|
      t.string :idpk, null: false
      t.string :message_type, null: false
      t.datetime :created_at, null: false
    end

    add_index :processed_messages, :idpk, unique: true
  end
end
