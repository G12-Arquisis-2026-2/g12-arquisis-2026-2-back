# Mensaje `error` de la central: rechazó la operación de un mensaje nuestro (data.target = su msgId).
# Queda en AuditLog como CENTRAL_ERROR, una sola vez por idpk. No se responde con ACK ni NACK
# (eso lo decide el connector: los errores de la central no se responden nunca).
class ErrorProcessorService
  # Errores que cierran la propuesta de negociación a la que apuntan (Enunciado § Errores)
  PROPOSAL_ERRORS = %w[PRICE_ABOVE_CAP OVER_CAPACITY CYCLE_EXPIRED CYCLE_UNKNOWN].freeze

  def self.call(payload)
    data = payload["data"].is_a?(Hash) ? payload["data"] : {}
    reason = payload["reason"].to_s

    ProcessedMessage.process_once(payload) do
      AuditLog.create!(
        idpk: payload.fetch("idpk"),
        event_type: AuditedEventService::EVENT_TYPES.fetch("error"),
        reason: reason.presence || data["target"].presence || "error",
        raw_payload: payload
      )

      if reason == "REPORT_TOO_EARLY"
        # el reporte llegó antes del periodo de cierre: se reenvía desde data.opensAt
        CycleService.report_too_early!(data["target"], data["opensAt"])
      elsif PROPOSAL_ERRORS.include?(reason)
        reject_proposal(payload, data)
      end
    end
  end

  # data.target es el msgId de la propuesta (cada reintento tiene uno nuevo, pero el mismo idpk):
  # el outbox lo traduce al idpk de la propuesta. Si no es una propuesta (p. ej. CYCLE_EXPIRED de un
  # reporte), solo queda el AuditLog.
  def self.reject_proposal(payload, data)
    target = data["target"].to_s
    outbox = OutboxMessage.find_by(msg_id: target, message_type: "negotiation-proposal") if target.present?
    proposal = Proposal.find_by(idpk: outbox.idpk) if outbox

    unless proposal
      Rails.logger.warn "[ErrorProcessor] #{payload['reason']} para #{target.presence || 'target vacío'}: no es una propuesta nuestra"
      return
    end

    if proposal.close!(:rejected, rejection_reason(payload, data))
      Rails.logger.warn "[ErrorProcessor] Propuesta #{proposal.idpk} rechazada por la central: #{proposal.status_reason}"
    else
      Rails.logger.info "[ErrorProcessor] #{payload['reason']} para la propuesta #{proposal.idpk}, que ya estaba #{proposal.status}"
    end
  end

  # "PRICE_ABOVE_CAP (422): <message> [cap=10.5]": el motivo legible y el dato para corregir el intento
  def self.rejection_reason(payload, data)
    text = payload["reason"].to_s
    text += " (#{payload['code']})" if payload["code"].present?
    text += ": #{data['message']}" if data["message"].present?
    extra = data.slice("cap", "spare").map { |key, value| "#{key}=#{value}" }
    text += " [#{extra.join(', ')}]" if extra.any?
    text
  end

  private_class_method :reject_proposal, :rejection_reason
end
