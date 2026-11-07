class CreateImbalanceSettlements < ActiveRecord::Migration[8.1]
  def change
    create_table :imbalance_settlements do |t|
      t.string :idpk, null: false
      t.string :msg_id, null: false
      t.string :cycle_id, null: false
      t.string :settlement_id, null: false
      t.integer :kwh_held, null: false
      t.integer :deficit, null: false
      t.integer :coverage, null: false
      t.decimal :price_per_energy, null: false
      t.decimal :total, null: false
      t.decimal :balance_after, null: false
      t.datetime :settled_at
      t.jsonb :raw_payload, null: false, default: {}
      t.timestamps
    end
    add_index :imbalance_settlements, :idpk, unique: true
    add_index :imbalance_settlements, :cycle_id
  end
end
