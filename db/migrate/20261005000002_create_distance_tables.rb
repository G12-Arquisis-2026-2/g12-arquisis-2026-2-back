class CreateDistanceTables < ActiveRecord::Migration[8.0]
  def change
    create_table :distance_tables do |t|
      t.string :destination_code, null: false
      t.integer :distance, null: false
      t.decimal :transport_cost, null: false
      t.boolean :enabled, null: false
    end
  end
end