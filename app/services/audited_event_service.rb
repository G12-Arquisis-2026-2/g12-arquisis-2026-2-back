# Mensajes del protocolo que no tienen modelo propio: quedan registrados en AuditLog,
# una sola vez por idpk.
class AuditedEventService
  EVENT_TYPES = {
    "give" => "GIVE",
    "take" => "TAKE",
    "demand-set" => "DEMAND_SET",
    # prefijo para no confundirlos con los NACK que publicamos nosotros (AuditLog.log_nack)
    "ack" => "CENTRAL_ACK",
    "nack" => "CENTRAL_NACK",
    "error" => "CENTRAL_ERROR"
  }.freeze

  def self.call(payload)
    type = payload.fetch("type")
    data = payload["data"].is_a?(Hash) ? payload["data"] : {}

    ProcessedMessage.process_once(payload) do
      AuditLog.create!(
        idpk: payload.fetch("idpk"),
        event_type: EVENT_TYPES.fetch(type),
        reason: reason_for(type, payload, data),
        raw_payload: payload
      )
    end
  end

  # give/take: la propuesta confirmada (data.target). Respuestas: el motivo que manda la central.
  def self.reason_for(type, payload, data)
    return data.fetch("target").to_s if %w[give take].include?(type)

    payload["reason"].presence || data["target"].presence || type
  end

  private_class_method :reason_for
end
