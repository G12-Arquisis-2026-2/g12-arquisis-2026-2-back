class AuditLog < ApplicationRecord
  validates :event_type, presence: true

  def self.log_nack(payload, reason_code)
    idpk = if payload.respond_to?(:key?)
      payload.key?("idpk") ? payload["idpk"] : payload[:idpk]
    end

    create!(
      idpk: idpk,
      event_type: "NACK",
      reason: reason_code,
      raw_payload: payload
    )
  rescue StandardError => error
    Rails.logger.error("AuditLog.log_nack failed: #{error.class}: #{error.message}")
    nil
  end

  # Respuesta de la central (ack/nack/error) que no se pudo procesar: igual queda como CENTRAL_<tipo>.
  def self.log_central(payload, reason)
    payload = payload.to_unsafe_h if payload.respond_to?(:to_unsafe_h)
    type = payload["type"] if payload.is_a?(Hash)

    create!(
      idpk: payload.is_a?(Hash) ? payload["idpk"].presence&.to_s : nil,
      event_type: AuditedEventService::EVENT_TYPES.fetch(type, "CENTRAL_UNKNOWN"),
      reason: reason,
      raw_payload: payload.is_a?(Hash) ? payload : { "raw" => payload }
    )
  rescue StandardError => error
    Rails.logger.error("AuditLog.log_central failed: #{error.class}: #{error.message}")
    nil
  end

  def self.log_discard(raw_string, reason)
    create!(
      idpk: nil,
      event_type: "DISCARDED",
      reason: reason,
      raw_payload: { "raw_string" => raw_string }
    )
  rescue StandardError => error
    Rails.logger.error("AuditLog.log_discard failed: #{error.class}: #{error.message}")
    nil
  end
end