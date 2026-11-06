class ProposalsController < ApplicationController
  # POST /proposals is intentionally disabled because negotiation-proposal is retired by the central.

  # GET /proposals
  # Lista el historial de propuestas reales registradas en la base de datos
  def index
    proposals = Proposal.order(created_at: :desc)
    render json: { proposals: proposals }, status: :ok
  end
end