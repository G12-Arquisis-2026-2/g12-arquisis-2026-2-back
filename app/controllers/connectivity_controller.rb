class ConnectivityController < ApplicationController
    def index
      render json: {
        cityId: "COR",
        updatedAt: Time.current.iso8601,
        distances: {
          "HGW" => { distance: 62763183, transportCost: 0.0034, enabled: true },
          "TAR" => { distance: 94306517, transportCost: 0.0013, enabled: true },
          "TAL" => { distance: 45012399, transportCost: 0.0025, enabled: false },
          "LSN" => { distance: 120543210, transportCost: 0.0041, enabled: true }
        }
      }, status: :ok
    end
  end