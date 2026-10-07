class AddStatusReasonToProposals < ActiveRecord::Migration[8.1]
  def change
    # por qué la propuesta quedó cerrada: error de la central (reason, code, message),
    # expirada por timeout o fallo al reintentar. Lo muestra el historial (RF04).
    add_column :proposals, :status_reason, :string
  end
end
