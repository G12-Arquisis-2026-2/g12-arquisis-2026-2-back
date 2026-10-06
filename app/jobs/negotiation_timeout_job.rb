class NegotiationTimeoutJob < ApplicationJob
  queue_as :default

  def perform(proposal_idpk)
    # Buscar la propuesta en la BD según lo definido en ADR3
    proposal = Proposal.find_by(idpk: proposal_idpk)
    return unless proposal

    # Si tras 30s sigue en estado PENDING, reintentar con el mismo idpk
    if proposal.status == 'PENDING'
      Rails.logger.warn "[ADR3 Timeout] Propuesta #{proposal_idpk} sin respuesta tras 30s. Reintentando..."

      payload = NegotiationService.build_proposal(
        cycle_id: proposal.cycle_id,
        direction: proposal.direction,
        quantity: proposal.quantity,
        generation_cost: proposal.generation_cost,
        existing_idpk: proposal.idpk # Mismo idpk (ADR3)
      )

      # Reenviar mediante el publicador de RabbitMQ 
      RabbitMQPublisher.publish(payload) if defined?(RabbitMQPublisher)

      # Agendar nuevamente la comprobación en 30 segundos
      NegotiationTimeoutJob.set(wait: 30.seconds).perform_later(proposal.idpk)
    else
      Rails.logger.info "[ADR3 Timeout] Propuesta #{proposal_idpk} resuelta previamente con estado: #{proposal.status}"
    end
  end
end