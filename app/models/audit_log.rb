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
  rescue StandardError
    nil
  end

  def self.log_discard(raw_string, reason)
    create!(
      idpk: nil,
      event_type: "DISCARDED",
      reason: reason,
      raw_payload: raw_string
    )
  rescue StandardError
    nil
  end
end