class AddUniqueIndexToDistanceTablesOnDestinationCode < ActiveRecord::Migration[8.0]
  def change
    add_index :distance_tables, :destination_code, unique: true
  end
end