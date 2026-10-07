class ErrorProcessorService
  # Errores exclusivos del flujo de propuestas de negociación
  PROPOSAL_SPECIFIC_ERRORS = %w[PRICE_ABOVE_CAP OVER_CAPACITY].freeze
  # Errores generales de ciclo
  CYCLE_ERRORS = %w[CYCLE_EXPIRED CYCLE_UNKNOWN].freeze

  def self.call(payload)
    new(payload).call
  end

  def initialize(payload)
    @payload = payload
  end

  def call
    reason = @payload["reason"]
    data = @payload["data"] || {}
    target_msg_id = data["target"]

    # 1. Caso REPORT_TOO_EARLY: Delegar directamente a CycleService
    if reason == "REPORT_TOO_EARLY"
      CycleService.report_too_early!(target_msg_id, data["opensAt"])
      record_audit_log(reason, data)
      return true
    end

    # 2. Buscar el tipo de mensaje original en el Outbox para desambiguar el destino
    outbox = OutboxMessage.find_by(msg_id: target_msg_id) if target_msg_id.present?
    message_type = outbox&.message_type

    # 3. Solo actualizar a REJECTED si se confirma que el error afectó a una propuesta
    if proposal_target?(reason, message_type, target_msg_id)
      reject_proposal_if_exists(target_msg_id, outbox)
    end

    record_audit_log(reason, data)
    true
  end

  private

  def proposal_target?(reason, message_type, target_msg_id)
    # Caso A: El outbox confirma que fue una propuesta de negociación
    return true if message_type == "negotiation-proposal"

    # Caso B: Es un error exclusivo de la negociación (PRICE_ABOVE_CAP u OVER_CAPACITY)
    return true if PROPOSAL_SPECIFIC_ERRORS.include?(reason)

    # Caso C: Para CYCLE_EXPIRED o CYCLE_UNKNOWN, solo aplica a propuesta si existe coincidencia explícita por ID
    if CYCLE_ERRORS.include?(reason) && target_msg_id.present?
      Proposal.exists?(idpk: target_msg_id) || Proposal.exists?(msg_id: target_msg_id)
    else
      false
    end
  end

  def reject_proposal_if_exists(target_msg_id, outbox)
    return unless target_msg_id.present?

    proposal_idpk = outbox&.idpk || target_msg_id
    proposal = Proposal.find_by(idpk: proposal_idpk) || Proposal.find_by(msg_id: target_msg_id)

    if proposal
      proposal.update!(status: "REJECTED")
      Rails.logger.warn "[ErrorProcessor] Propuesta #{proposal.idpk} rechazada por la central. Target: #{target_msg_id}"
    else
      Rails.logger.warn "[ErrorProcessor] Error de propuesta recibido, pero no se encontró la propuesta para target #{target_msg_id}"
    end
  end

  def record_audit_log(reason, data)
    AuditLog.create!(
      idpk: @payload["idpk"] || SecureRandom.uuid,
      event_type: "CENTRAL_ERROR",
      reason: "#{reason}: #{data['message']}",
      raw_payload: @payload
    )
  end
end