class FeedEvent < ApplicationRecord
    validates :event_type, presence: true
  
    scope :recent, ->(limit = 50) { order(id: :desc).limit(limit) }
    scope :since_id, ->(last_id) { where('id > ?', last_id.to_i).order(id: :asc) }
  
    # Método estándar para procesar eventos o transiciones
    def self.publish(event_type:, payload: {}, cycle_id: nil, swap_id: nil, idpk: nil)
      event = create!(
        event_type: event_type,
        cycle_id: cycle_id,
        swap_id: swap_id,
        idpk: idpk,
        payload: payload
      )
  
      # Notificación inmediata por PostgreSQL LISTEN/NOTIFY para evitar polling agresivo en SSE
      connection.execute("NOTIFY feed_events_channel, '#{event.id}'")
      event
    rescue StandardError => e
      Rails.logger.error({
        event: 'feed_event_publish_error',
        event_type: event_type,
        cycleId: cycle_id,
        swapId: swap_id,
        idpk: idpk,
        error: e.message
      }.to_json)
      nil
    end
  
    def to_sse_json
      {
        id: id,
        type: event_type,
        cycleId: cycle_id,
        swapId: swap_id,
        idpk: idpk,
        payload: payload,
        timestamp: created_at.iso8601
      }.to_json
    end
end