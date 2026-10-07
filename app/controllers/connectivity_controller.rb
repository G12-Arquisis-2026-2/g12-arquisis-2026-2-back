# RF02: tabla de conectividad vigente, armada desde las distance-table que mandó la central.
# Forma que espera el front (ConnectivityResponse): { cityId, updatedAt, distances: { CODE => { distance, transportCost, enabled } } }
class ConnectivityController < ApplicationController
  def index
    distances = DistanceTable.order(:destination_code).to_h do |route|
      [route.destination_code, { distance: route.distance, transportCost: route.transport_cost.to_f, enabled: route.enabled }]
    end

    render json: {
      cityId: ENV.fetch("CITY_ID", "TK3"),
      # cuándo llegó la última distance-table; nil si todavía no llega ninguna
      updatedAt: ProcessedMessage.where(message_type: "distance-table").maximum(:created_at)&.iso8601,
      distances: distances
    }, status: :ok
  end
end
