class EventsController < ApplicationController
  skip_before_action :verify_authenticity_token, raise: false

  # Errores causados por el contenido del mensaje: no sirve reintentarlos.
  MALFORMED_ERRORS = [
    KeyError,
    ArgumentError,
    NoMethodError,
    JSON::ParserError,
    ActionDispatch::Http::Parameters::ParseError,
    ActiveRecord::RecordInvalid
  ].freeze

  PROCESSORS = {
    'transfer' => LedgerProcessorService,
    'demand-statement' => LedgerProcessorService,
    'give' => LedgerProcessorService,
    'take' => LedgerProcessorService,
    'status-statement' => StatusStatementProcessorService,
    'distance-table' => DistanceTableProcessorService,
    'error' => ErrorProcessorService
  }.merge(AuditedEventService::EVENT_TYPES.keys.index_with(AuditedEventService)).freeze

  def create
    payload = params.except(:controller, :action).permit!.to_h
    type = payload['type']

    unless PROCESSORS.key?(type)
      return render json: { error: 'UNKNOWN_TYPE', detail: "type #{type.inspect} is not supported" },
                    status: :unprocessable_content
    end

    EventPayloadValidator.validate!(payload)

    if PROCESSORS.fetch(type).call(payload)
      render json: { status: 'saved' }, status: :created
    else
      render json: { status: 'duplicate', detail: 'IDPK already exists' }, status: :ok
    end
  rescue *MALFORMED_ERRORS => e
    Rails.logger.warn "Mensaje malformado (#{e.class}): #{e.message}"
    render json: { error: 'MALFORMED_MESSAGE', detail: e.message.to_s.truncate(200) },
           status: :unprocessable_content
  rescue StandardError => e
    Rails.logger.error "Error interno (#{e.class}): #{e.message}"
    render json: { error: 'Internal Server Error' }, status: :internal_server_error
  end

  def rejected
    case params[:kind]
    when 'nack'
      AuditLog.log_nack(params[:raw], params[:reason])
    when 'central'
      AuditLog.log_central(params[:raw], params[:reason])
    else
      AuditLog.log_discard(params[:raw], params[:reason])
    end
    
    render json: { status: 'logged' }, status: :created
  end
end