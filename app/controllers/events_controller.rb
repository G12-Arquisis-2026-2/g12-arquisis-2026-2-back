class EventsController < ApplicationController
  skip_before_action :verify_authenticity_token

  def create
    payload = params.except(:controller, :action).permit!.to_h

    begin
      case payload['type']
      when 'transfer', 'demand-statement'
        if LedgerProcessorService.call(payload)
          render json: { status: 'saved' }, status: :created
        else
          render json: { status: 'duplicate', detail: 'IDPK already exists' }, status: :ok
        end

      when 'distance-table'
        DistanceTableProcessorService.call(payload)
        render json: { status: 'saved' }, status: :created

      else
        render json: { status: 'forwarded' }, status: :created
      end
    rescue => e
      Rails.logger.error "Error interno: #{e.message}"
      render json: { error: 'Internal Server Error' }, status: :internal_server_error
    end
  end

  def rejected
    if params[:kind] == 'nack'
      AuditLog.log_nack(params[:raw], params[:reason])
    else
      AuditLog.log_discard(params[:raw], params[:reason])
    end
    
    render json: { status: 'logged' }, status: :created
  end
end