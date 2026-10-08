class CreateTransactions < ActiveRecord::Migration[8.0]
  def change
    create_table :transactions do |t|
      t.string :idpk, null: false
      t.string :cycle_id, null: false
      t.string :operation_type, null: false
      t.decimal :energy_change, null: false
      t.decimal :budget_change, null: false
      t.jsonb :raw_data, null: false, default: {}

      t.datetime :created_at, null: false
    end

    add_index :transactions, :idpk, unique: true
    add_index :transactions, :cycle_id
  end
end