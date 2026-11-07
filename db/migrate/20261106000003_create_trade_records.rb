class CreateTradeRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :trade_records do |t|
      t.string :idpk, null: false
      t.string :msg_id, null: false
      t.string :cycle_id, null: false
      t.string :swap_id, null: false
      t.string :offer_id, null: false
      t.string :seller, null: false
      t.string :buyer, null: false
      t.integer :quantity, null: false
      t.decimal :price_per_energy, null: false
      t.decimal :energy_total, null: false
      t.decimal :transport_per_energy, null: false
      t.decimal :transport_total, null: false
      t.boolean :route_enabled, null: false
      t.datetime :recorded_at
      t.jsonb :raw_payload, null: false, default: {}
      t.timestamps
    end
    add_index :trade_records, :idpk, unique: true
    add_index :trade_records, :cycle_id
  end
end
