class CreateCycles < ActiveRecord::Migration[8.1]
  def change
    create_table :cycles do |t|
      t.string :cycle_id
      t.decimal :generation_capacity
      t.decimal :consumption
      t.decimal :generation_cost
      t.decimal :reported_budget
      t.decimal :reported_energy
      t.boolean :report_sent

      t.timestamps
    end
    add_index :cycles, :cycle_id, unique: true
  end
end
