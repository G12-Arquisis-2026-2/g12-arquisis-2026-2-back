class CreateSwapIntentions < ActiveRecord::Migration[8.1]
  def change
    create_table :swap_intentions do |t|
      t.string :idpk, null: false
      t.string :swap_id
      t.integer :status, null: false, default: 0
      t.decimal :give_amount
      t.decimal :take_amount
      t.datetime :expires_at

      t.timestamps
    end

    add_index :swap_intentions, :idpk, unique: true
  end
end
