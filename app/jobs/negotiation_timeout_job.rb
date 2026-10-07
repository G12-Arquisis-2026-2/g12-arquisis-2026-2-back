class NegotiationTimeoutJob < ApplicationJob
  queue_as :default

  def perform(proposal_idpk)
    proposal = Proposal.find_by(idpk: proposal_idpk)
    return unless proposal

    # 1. Si la propuesta ya fue confirmada o resuelta, detener el bucle
    # (incluye rechazada por un error de la central: no se reintenta)
    unless proposal.pending?
      Rails.logger.info "[ADR3 Timeout] Propuesta #{proposal_idpk} resuelta previamente con estado: #{proposal.status}"
      return
    end

    # 2. Verificar si la ventana de negociación del ciclo ya terminó/expiró
    cycle = Cycle.find_by(cycle_id: proposal.cycle_id)
    if cycle_expired?(cycle)
      proposal.close!(:expired, "Expirada por timeout: sin confirmación antes del cierre de la ventana del ciclo #{proposal.cycle_id}")
      Rails.logger.warn "[ADR3 Timeout] Ventana de negociación para el ciclo #{proposal.cycle_id} finalizada. Deteniendo reintentos de propuesta #{proposal_idpk}."
      return
    end

    # 3. Si sigue en PENDING y el ciclo sigue activo, reintentar (ADR3)
    Rails.logger.warn "[ADR3 Timeout] Propuesta #{proposal_idpk} sin respuesta tras 30s. Reintentando..."

    payload = NegotiationService.build_proposal(
      cycle_id: proposal.cycle_id,
      direction: proposal.direction,
      energy: proposal.quantity,
      existing_idpk: proposal.idpk # Reutiliza idpk según ADR3
    )

    RabbitMQPublisher.publish(payload) if defined?(RabbitMQPublisher)

    # Reagendar comprobación en 30 segundos
    NegotiationTimeoutJob.set(wait: 30.seconds).perform_later(proposal.idpk)
  rescue ActiveRecord::RecordNotFound, NegotiationService::OverCapacityError, NegotiationService::PriceCapExceededError => e
    Rails.logger.error "[ADR3 Timeout] No se pudo reintentar la propuesta #{proposal_idpk}: #{e.message}"
    proposal&.close!(:failed, "Reintento fallido (#{e.class.name.demodulize}): #{e.message}")
  end

  private

  def cycle_expired?(cycle)
    return true unless cycle
    # El ciclo expiró si superó la fecha/hora valid_until
    cycle.valid_until.present? && Time.current >= cycle.valid_until
  end
end