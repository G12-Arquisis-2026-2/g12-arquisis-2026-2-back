# Reserva de filas para el relay (ADR8): una fila reservada no la publica otro relay, y si el relay
# muere sin marcarla, locked_until vence y vuelve a estar disponible.
class AddClaimToOutboxMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :outbox_messages, :locked_until, :datetime
    add_column :outbox_messages, :locked_by, :string
    add_index :outbox_messages, [:status, :created_at]
  end
end
