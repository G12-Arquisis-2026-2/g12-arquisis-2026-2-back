class AddValidUntilToCycles < ActiveRecord::Migration[8.1]
  def change
    add_column :cycles, :valid_until, :datetime
  end
end