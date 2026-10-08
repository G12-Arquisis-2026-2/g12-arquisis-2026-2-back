class AddTransferTrackingToProposals < ActiveRecord::Migration[8.1]
  def change
    # Espera del transfer de un give confirmado (Enunciado § Pago): cuándo se confirmó,
    # cuántas veces se reintentó la operación con el mismo idpk y cuándo fue el último reintento.
    add_column :proposals, :confirmed_at, :datetime
    add_column :proposals, :transfer_retries, :integer, null: false, default: 0
    add_column :proposals, :last_transfer_retry_at, :datetime
  end
end
