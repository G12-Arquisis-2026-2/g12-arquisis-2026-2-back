module Api
  module V1
    class DistancesController < ApplicationController
      def index
        render json: DistanceTable.all, status: :ok
      end
    end
  end
end