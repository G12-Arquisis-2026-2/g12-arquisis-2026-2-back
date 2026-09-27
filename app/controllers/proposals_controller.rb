class ProposalsController < ApplicationController
    # GET /proposals
    def index
      render json: {
        proposals: [
          {
            id: "prop-101",
            cycleId: "cycle-9431",
            direction: "take",
            quantity: 2024,
            pricePerEnergy: 210,
            status: "confirmed", # confirmed, paid, timeout
            createdAt: (Time.current - 10.minutes).iso8601
          },
          {
            id: "prop-102",
            cycleId: "cycle-9431",
            direction: "give",
            quantity: 500,
            pricePerEnergy: 220.5,
            status: "timeout",
            createdAt: (Time.current - 25.minutes).iso8601
          }
        ]
      }, status: :ok
    end
  
    # POST /proposals
    def create
      # En desarrollo simulamos la recepción de la propuesta enviada desde el formulario React
      proposal_params = params.permit(:cycleId, :direction, :quantity, :pricePerEnergy)
  
      # Validación básica
      if proposal_params[:quantity].to_f <= 0 || proposal_params[:pricePerEnergy].to_f <= 0
        return render json: { error: "Quantity and price must be positive numbers" }, status: :unprocessable_entity
      end
  
      render json: {
        status: "pending",
        message: "Propuesta registrada e iniciada en la cola de RabbitMQ",
        proposal: proposal_params.merge(id: SecureRandom.uuid, createdAt: Time.current.iso8601)
      }, status: :created
    end
  end