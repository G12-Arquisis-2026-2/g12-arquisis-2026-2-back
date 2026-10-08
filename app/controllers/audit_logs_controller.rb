# RF05: anomalías registradas en AuditLog, en la forma que espera el front (AuditLogsResponse):
#   duplicates:       idpk repetidos que no tocaron el ledger (DUPLICATE)
#   rejectedMessages: NACK que publicamos, mensajes descartados por el connector y rechazos de la central
# /api/v1/audit-logs devuelve las mismas filas sin adaptar.
class AuditLogsController < ApplicationController
  # tope por lista para que la página no crezca sin límite (los más recientes primero)
  LIMIT = 200

  REJECTION_TYPES = {
    "NACK" => "nack",
    "DISCARDED" => "discarded",
    "CENTRAL_NACK" => "nack",
    "CENTRAL_ERROR" => "error",
    "CENTRAL_UNKNOWN" => "discarded"
  }.freeze

  # códigos de los NACK que publica el connector (connector/lib/message_validator.rb y message_processor.rb)
  NACK_CODES = {
    "MALFORMED_MESSAGE" => 422,
    "IDPK_EQUALS_MSGID" => 422,
    "UNKNOWN_TYPE" => 400
  }.freeze

  def index
    duplicates = AuditLog.where(event_type: "DUPLICATE").order(created_at: :desc, id: :desc).limit(LIMIT).to_a
    rejected = AuditLog.where(event_type: REJECTION_TYPES.keys).order(created_at: :desc, id: :desc).limit(LIMIT)
    original_msg_ids = original_msg_ids_for(duplicates.map(&:idpk))

    render json: {
      duplicates: duplicates.map { |log| duplicate_json(log, original_msg_ids[log.idpk]) },
      rejectedMessages: rejected.map { |log| rejected_json(log) }
    }, status: :ok
  end

  private

  def duplicate_json(log, original_msg_id)
    raw = payload_of(log)
    {
      idpk: log.idpk,
      originalMsgId: original_msg_id,
      duplicateMsgId: raw["msgId"],
      type: raw["type"],
      detectedAt: log.created_at.iso8601,
      action: "ignored_ledger_unchanged"
    }
  end

  def rejected_json(log)
    raw = payload_of(log)
    type = REJECTION_TYPES.fetch(log.event_type)
    {
      msgId: raw["msgId"],
      reason: log.reason,
      code: code_for(log, raw),
      message: message_for(log, raw),
      timestamp: log.created_at.iso8601,
      type: type
    }
  end

  # NACK propio: el código va según el motivo. Rechazo de la central: el code que mandó ella.
  def code_for(log, raw)
    return NACK_CODES[log.reason] if log.event_type == "NACK"

    raw["code"]
  end

  def message_for(log, raw)
    case log.event_type
    when "DISCARDED"
      # lo que llegó tal cual (texto o mensaje), recortado
      original = log.raw_payload.is_a?(Hash) ? log.raw_payload["raw_string"] : nil
      (original.is_a?(String) ? original : original&.to_json).to_s.truncate(200)
    when "NACK"
      [raw["type"], raw["idpk"] && "idpk #{raw['idpk']}"].compact.join(" ")
    else
      data = raw["data"].is_a?(Hash) ? raw["data"] : {}
      (data["message"].presence || data["target"].presence).to_s
    end
  end

  # El mensaje original del log. En un descarte por MAX_RETRIES_EXCEEDED el connector manda el mensaje entero.
  def payload_of(log)
    raw = log.raw_payload.is_a?(Hash) ? log.raw_payload : {}
    raw["raw_string"].is_a?(Hash) ? raw["raw_string"] : raw
  end

  # msgId del primer mensaje con ese idpk: está en el ledger (transfer, demand-statement, give, take) o en
  # AuditLog (respuestas de la central, demand-set). status-statement y distance-table no lo guardan: nil.
  def original_msg_ids_for(idpks)
    idpks = idpks.compact.uniq
    return {} if idpks.empty?

    from_audit = AuditLog.where(idpk: idpks).where.not(event_type: "DUPLICATE")
                         .order(:created_at).pluck(:idpk, Arel.sql("raw_payload ->> 'msgId'"))
    from_ledger = Transaction.where(idpk: idpks).pluck(:idpk, Arel.sql("raw_data ->> 'msgId'"))

    (from_audit.reverse + from_ledger).to_h.compact
  end
end
