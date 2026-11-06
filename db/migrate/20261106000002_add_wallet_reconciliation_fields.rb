class AddWalletReconciliationFields < ActiveRecord::Migration[8.1]
  def change
    add_column :cycles, :cr_delta, :decimal, precision: 20, scale: 2
    add_column :cycles, :kwh_delta, :decimal, precision: 20, scale: 2
    add_column :cycles, :reconciliation_scheduled_at, :datetime
    add_column :cycles, :reconciled_at, :datetime

    add_column :swap_intentions, :cycle_id, :string
    add_column :swap_intentions, :cancel_idempotency_key, :string
    add_index :swap_intentions, :cycle_id
    add_index :swap_intentions, :cancel_idempotency_key, unique: true
  end
end
