class CreateMarketStrategies < ActiveRecord::Migration[8.1]
  def change
    create_table :market_strategies do |t|
      t.decimal :sell_price_multiplier, precision: 8, scale: 4, null: false, default: 1.1
      t.decimal :max_buy_effective_price_ratio, precision: 8, scale: 4, null: false, default: 1.0
      t.integer :span_seconds, null: false, default: 60
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :market_strategies, :active, unique: true, where: "active"
    add_reference :cycles, :market_strategy, foreign_key: true
    add_column :cycles, :sellable, :integer
    add_column :cycles, :buyback_price, :decimal, precision: 15, scale: 2
    add_column :cycles, :imbalance_price, :decimal, precision: 15, scale: 2
    add_column :cycles, :min_bid, :integer
    add_column :cycles, :market_opens_at, :datetime
    add_column :cycles, :last_offer_at, :datetime
    add_column :cycles, :last_bid_at, :datetime
    add_column :cycles, :closes_at, :datetime
    add_column :cycles, :report_opens_at, :datetime
    add_column :distance_tables, :disabled_route_transport_cost, :decimal, precision: 15, scale: 6
  end
end
