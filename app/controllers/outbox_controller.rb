# Rutas internas que usa el connector para publicar los mensajes pendientes.
class OutboxController < ApplicationController
  # El connector pide de a pocos y vuelve a preguntar cada 2 segundos.
  BATCH_SIZE = 50

  # GET /events/outbox
  def pending
    messages = OutboxMessage.pending.limit(BATCH_SIZE)
    render json: messages.map { |message| { id: message.id, payload: message.payload } }
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
end
