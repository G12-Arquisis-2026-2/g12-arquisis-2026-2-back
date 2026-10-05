class CreateProposals < ActiveRecord::Migration[7.1]
  def change
    create_table :proposals do |t|
      t.string :idpk, null: false
      t.string :cycle_id, null: false
      t.string :direction, null: false
      t.decimal :quantity, precision: 15, scale: 2, null: false
      t.decimal :price_per_energy, precision: 15, scale: 2
      t.decimal :generation_cost, precision: 15, scale: 2, null: false
      t.string :status, null: false, default: 'PENDING'

      t.timestamps
    end

    add_index :proposals, :idpk, unique: true # Unicidad de idpk
    add_index :proposals, :cycle_id
  end
end