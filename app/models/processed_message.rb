# Registro de idpk ya procesados para mensajes que no dejan una fila propia con idpk
# (status-statement, distance-table). La unicidad la garantiza el índice de la BD.
class ProcessedMessage < ApplicationRecord
  # Ejecuta el bloque solo si el idpk es nuevo, todo en una misma transacción.
  # Devuelve true si se procesó y false si era un duplicado (queda en AuditLog).
  def self.process_once(payload)
    transaction(requires_new: true) do
      create!(idpk: payload.fetch("idpk"), message_type: payload.fetch("type"))
      yield
    end
    true
  rescue ActiveRecord::RecordNotUnique
    AuditLog.create!(
      idpk: payload.fetch("idpk"),
      event_type: "DUPLICATE",
      reason: "Message rejected due to retry",
      raw_payload: payload
    )
    false
  end
end
