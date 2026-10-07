class ProposalsController < ApplicationController
  # GET /proposals
  # Lista el historial de propuestas reales registradas en la base de datos
  def index
    proposals = Proposal.order(created_at: :desc)
    render json: { proposals: proposals }, status: :ok
  end

  # POST /proposals
  # Crea la propuesta, valida reglas de negocio, persiste en BD, publica a RabbitMQ y programa el timeout
  def create
    cycle_id  = params[:cycleId] || params[:cycle_id]
    direction = params[:direction]
    energy    = (params[:energy] || params[:quantity]).to_f

    # 1. Validación inicial de parámetros
    if energy <= 0
      return render json: { error: "Energy/Quantity must be a positive number" }, status: :unprocessable_entity
    end

    if cycle_id.blank? || direction.blank?
      return render json: { error: "cycleId and direction are required" }, status: :unprocessable_entity
    end

    # 2. Construcción y validación mediante NegotiationService
    # Genera el payload Envelope v2 y valida topes (PRICE_ABOVE_CAP y OVER_CAPACITY)
    payload = NegotiationService.build_proposal(
      cycle_id: cycle_id,
      direction: direction,
      energy: energy
    )

    cycle = Cycle.find_by!(cycle_id: cycle_id)

    # 3. Guardar la propuesta (quantity = energía) y 4. publicarla hacia la central (outbox_messages,
    # para el connector) en una sola transacción: si falla el publish no queda una propuesta sin mensaje
    proposal = Proposal.transaction do
      created = Proposal.create!(
        idpk: payload[:idpk],
        cycle_id: payload[:cycleId],
        direction: payload[:data][:direction],
        quantity: payload[:data][:quantity],
        price_per_energy: payload[:data][:pricePerEnergy],
        generation_cost: cycle.generation_cost,
        status: "PENDING"
      )
      RabbitMQPublisher.publish(payload)
      created
    end

    # 5. Agendar la verificación de timeout de 30 segundos (ADR3)
    NegotiationTimeoutJob.set(wait: 30.seconds).perform_later(proposal.idpk)

    # 6. Respuesta exitosa
    render json: {
      status: "pending",
      message: "Propuesta creada, guardada e iniciada en la cola de RabbitMQ",
      proposal: proposal
    }, status: :created

  rescue ActiveRecord::RecordNotFound => e
    render json: { error: e.message }, status: :not_found

  rescue NegotiationService::OverCapacityError, NegotiationService::PriceCapExceededError, ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity

  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages }, status: :unprocessable_entity
  end
end