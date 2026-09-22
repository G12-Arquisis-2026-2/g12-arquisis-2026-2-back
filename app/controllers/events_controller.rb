class EventsController < ApplicationController
    def create
      raw_data = params.permit(:idpk, :type, packageBody: {}).to_h
  
      event = DemandEvent.find_or_initialize_by(idpk: raw_data['idpk'])
      event.event_type   = raw_data['type']
      event.package_body = raw_data['packageBody']
      event.received_at  = Time.current
  
      if event.save
        render json: { status: 'created', id: event.id }, status: :created
      else
        render json: { errors: event.errors.full_messages }, status: :unprocessable_entity
      end
    end
  end