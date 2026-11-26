class EventFeedController < ApplicationController
    include ActionController::Live
  
    skip_before_action :authenticate_user!, only: [:stream], raise: false
  
    # POST /events/ticket
    # Protegido por JWT (Auth0 + API Gateway). Devuelve un ticket de un solo uso válido por 30s.
    def ticket
      user_sub = respond_to?(:current_user) ? current_user&.dig('sub') : nil
      token = FeedTicket.issue(user_sub: user_sub)
  
      render json: {
        ticket: token,
        expiresIn: FeedTicket::TTL.to_i
      }, status: :created
    end
  
    # GET /events/feed
    # Hidratación inicial de eventos recientes (protegido por JWT)
    def index
      limit = [params.fetch(:limit, 50).to_i, 100].min
      events = FeedEvent.recent(limit).reverse
  
      render json: {
        events: events.map do |e|
          {
            id: e.id,
            type: e.event_type,
            cycleId: e.cycle_id,
            swapId: e.swap_id,
            idpk: e.idpk,
            payload: e.payload,
            timestamp: e.created_at.iso8601
          }
        end
      }, status: :ok
    end
  
    # GET /events/stream?ticket=<TOKEN>
    # Stream continuo en tiempo real vía Server-Sent Events (SSE)
    def stream
      ticket_data = FeedTicket.consume!(params[:ticket])
  
      unless ticket_data
        return render json: {
          error: 'INVALID_OR_EXPIRED_TICKET',
          detail: 'El ticket SSE es inválido, ya fue utilizado o expiró (TTL 30s).'
        }, status: :unauthorized
      end
  
      response.headers['Content-Type']      = 'text/event-stream'
      response.headers['Cache-Control']     = 'no-cache'
      response.headers['X-Accel-Buffering'] = 'no'
  
      last_id = (request.headers['Last-Event-ID'] || params[:lastEventId]).to_i
      sse = SSE.new(response.stream, retry: 3000)
  
      # 1. Re-enviar eventos perdidos desde Last-Event-ID (o últimos 20 si es primera conexión)
      initial_events = if last_id.positive?
                         FeedEvent.since_id(last_id).limit(100)
                       else
                         FeedEvent.recent(20).reverse
                       end
  
      initial_events.each do |ev|
        sse.write(ev.to_sse_json, id: ev.id, event: ev.event_type)
        last_id = ev.id
      end
  
      # 2. Loop en vivo con heartbeat cada 15 segundos (10 iteraciones de 1.5s)
      idle_ticks = 0
      loop do
        new_events = FeedEvent.since_id(last_id).limit(50)
  
        if new_events.any?
          new_events.each do |ev|
            sse.write(ev.to_sse_json, id: ev.id, event: ev.event_type)
            last_id = ev.id
          end
          idle_ticks = 0
        else
          idle_ticks += 1
          if idle_ticks >= 10
            response.stream.write(": heartbeat #{Time.current.iso8601}\n\n")
            idle_ticks = 0
          end
        end
  
        sleep 1.5
      end
    rescue ActionController::Live::ClientDisconnected, IOError
      # Desconexión limpia del cliente
    ensure
      sse&.close
    end
end