class NegotiationTimeoutJob < ApplicationJob
  queue_as :default

  RETRY_BUILD_ERRORS = [
    ActiveRecord::RecordNotFound,
    NegotiationService::OverCapacityError,
    NegotiationService::PriceCapExceededError
  ].freeze

  # Sin transfer_attempt: espera la confirmación de una propuesta pendiente (ADR3).
  # Con transfer_attempt: espera el transfer de un give ya confirmado (Enunciado § Pago). El número
  # identifica la espera vigente: un job duplicado o atrasado no reintenta dos veces la operación.
  def perform(proposal_idpk, transfer_attempt: nil)
    return wait_for_transfer(proposal_idpk, transfer_attempt) unless transfer_attempt.nil?

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

    RabbitMQPublisher.publish(retry_payload(proposal)) if defined?(RabbitMQPublisher)

    # Reagendar comprobación en 30 segundos
    NegotiationTimeoutJob.set(wait: 30.seconds).perform_later(proposal.idpk)
  rescue *RETRY_BUILD_ERRORS => e
    Rails.logger.error "[ADR3 Timeout] No se pudo reintentar la propuesta #{proposal_idpk}: #{e.message}"
    proposal&.close!(:failed, "Reintento fallido (#{e.class.name.demodulize}): #{e.message}")
  end

  private

  # Give confirmado: si a los 30 s de la confirmación (o del último reintento) no llegó el transfer,
  # se asume que no hubo operación real y se reintenta con el mismo idpk y un msgId nuevo, hasta
  # Proposal::MAX_TRANSFER_RETRIES veces y solo mientras la ventana del ciclo siga abierta.
  def wait_for_transfer(proposal_idpk, attempt)
    proposal = Proposal.find_by(idpk: proposal_idpk)
    return unless proposal

    next_check_at = proposal.with_lock do
      # Cerrada (paid, rejected, expired, failed) o no es un give confirmado: no hay nada que esperar
      next unless proposal.confirmed? && proposal.give?
      # Otra espera ya avanzó (job duplicado o atrasado): no se reintenta dos veces el mismo intento
      next unless proposal.transfer_retries == attempt

      if proposal.transfer_received?
        proposal.update!(status: :paid)
        next
      end

      # Corrió antes de cumplir los 30 s: se vuelve a mirar cuando se cumplan
      next proposal.transfer_due_at if Time.current < proposal.transfer_due_at

      if cycle_expired?(Cycle.find_by(cycle_id: proposal.cycle_id))
        close_unpaid!(proposal, "Transfer no recibido antes del cierre de la ventana del ciclo " \
                                "#{proposal.cycle_id} (#{proposal.transfer_retries} reintentos)")
        next
      end

      if proposal.transfer_retries >= Proposal::MAX_TRANSFER_RETRIES
        close_unpaid!(proposal, "Transfer no recibido tras #{proposal.transfer_retries} reintentos")
        next
      end

      Rails.logger.warn "[Pago] Give #{proposal_idpk} sin transfer tras 30s. Reintentando con el mismo idpk..."
      RabbitMQPublisher.publish(retry_payload(proposal))
      proposal.update!(transfer_retries: attempt + 1, last_transfer_retry_at: Time.current)
      proposal.transfer_due_at
    end

    return unless next_check_at

    NegotiationTimeoutJob.set(wait_until: next_check_at)
                         .perform_later(proposal.idpk, transfer_attempt: proposal.transfer_retries)
  rescue *RETRY_BUILD_ERRORS => e
    Rails.logger.error "[Pago] No se pudo reintentar el give #{proposal_idpk}: #{e.message}"
    proposal&.close!(:failed, "Reintento por transfer fallido (#{e.class.name.demodulize}): #{e.message}",
                     from: :confirmed)
  end

  def close_unpaid!(proposal, reason)
    Rails.logger.warn "[Pago] Give #{proposal.idpk} cerrado: #{reason}"
    proposal.close!(:failed, reason, from: :confirmed)
  end

  def retry_payload(proposal)
    NegotiationService.build_proposal(
      cycle_id: proposal.cycle_id,
      direction: proposal.direction,
      energy: proposal.quantity, # quantity guarda la energía: el reintento pide la misma
      existing_idpk: proposal.idpk # Reutiliza idpk según ADR3 (msgId nuevo)
    )
  end

  def cycle_expired?(cycle)
    return true unless cycle
    # El ciclo expiró si superó la fecha/hora valid_until
    cycle.valid_until.present? && Time.current >= cycle.valid_until
  end
end
