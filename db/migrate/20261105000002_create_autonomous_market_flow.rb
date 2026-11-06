class CreateAutonomousMarketFlow < ActiveRecord::Migration[8.1]
  def change
    add_column :cycles, :market_opens_at, :datetime unless column_exists?(:cycles, :market_opens_at)

    create_table :market_offers do |t|
      t.string :cycle_id, null: false
      t.string :offer_id, null: false
      t.string :city_id, null: false
      t.integer :quantity, null: false
      t.integer :remaining, null: false
      t.integer :reserved_quantity, null: false, default: 0
      t.decimal :price_per_energy, precision: 15, scale: 2, null: false
      t.boolean :active, null: false, default: true
      t.jsonb :raw_payload, null: false, default: {}
      t.timestamps
    end
    add_index :market_offers, %i[cycle_id city_id offer_id], unique: true
    add_index :market_offers, %i[cycle_id active remaining]

    create_table :market_bids do |t|
      t.string :cycle_id, null: false
      t.string :offer_id, null: false
      t.string :bid_idpk, null: false
      t.string :bid_msg_id, null: false
      t.string :side, null: false
      t.string :buyer_city, null: false
      t.string :seller_city, null: false
      t.integer :quantity, null: false
      t.decimal :price_per_energy, precision: 15, scale: 2
      t.decimal :amount, precision: 15, scale: 2
      t.string :status, null: false, default: "pending"
      t.string :proposal_idpk
      t.string :accept_idpk
      t.string :swap_id
      t.datetime :expires_at
      t.jsonb :raw_payload, null: false, default: {}
      t.timestamps
    end
    add_index :market_bids, :bid_idpk, unique: true
    add_index :market_bids, :bid_msg_id, unique: true
    add_index :market_bids, :proposal_idpk, unique: true
    add_index :market_bids, :accept_idpk, unique: true
    add_index :market_bids, :swap_id
    add_index :market_bids, %i[cycle_id side status]
  end
end
