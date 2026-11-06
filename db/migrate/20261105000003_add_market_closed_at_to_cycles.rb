class AddMarketClosedAtToCycles < ActiveRecord::Migration[8.1]
  def change
    add_column :cycles, :market_closed_at, :datetime
  end
end
