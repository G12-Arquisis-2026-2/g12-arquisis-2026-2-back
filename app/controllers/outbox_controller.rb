# Rutas internas que usa el connector para publicar los mensajes pendientes.
class OutboxController < ApplicationController
  # El connector pide de a pocos y vuelve a preguntar cada 2 segundos.
  BATCH_SIZE = 50

  # GET /events/outbox  (relay sin reserva; se mantiene para volver atrás con OUTBOX_CLAIM_ENABLED=false)
  def pending
    OutboxMessage.expire_late_reports!
    render json: OutboxMessage.pending.limit(BATCH_SIZE).map { |message| item(message) }
  end

  # POST /events/outbox/claim   { "relay": "connector-1" }
  def claim
    relay = params[:relay].to_s
    return render json: { error: "relay is required" }, status: :unprocessable_entity if relay.blank?

    OutboxMessage.expire_late_reports!
    render json: OutboxMessage.claim!(relay: relay, limit: BATCH_SIZE).map { |message| item(message) }
  end

  # GET /events/outbox/current-offer: nuestra última oferta enviada del ciclo vigente, o 204 si no hay
  def current_offer
    cycle = Cycle.where.not(valid_until: nil).order(valid_until: :desc).first
    offer = OutboxMessage.last_sent_offer(cycle.cycle_id) if offer_open?(cycle)
    return head :no_content unless offer

    render json: item(offer)
  end

  # POST /events/outbox/:id   { "status": "sent" }  o  { "status": "failed", "reason": "..." }
  def result
    message = OutboxMessage.find_by(id: params[:id])
    return render json: { error: "not found" }, status: :not_found unless message

    case params[:status]
    when "sent" then message.mark_sent!
    when "failed" then message.mark_failed!(params[:reason])
    else return render json: { error: "status must be sent or failed" }, status: :unprocessable_entity
    end

    render json: { id: message.id, status: message.status }
  end

  private

  def item(message)
    message.slice(:id, :payload, :exchange, :routing_key)
  end

  # Igual que antes en el connector: solo mientras el ciclo acepta ofertas
  def offer_open?(cycle, now = Time.current)
    cycle && cycle.market_closed_at.nil? && cycle.last_offer_at && now < cycle.last_offer_at
  end
end
