class HistoryController < ApplicationController
  # RF1, RF3, RF4
  def index
    # RF3: Paginación
    page   = [params.fetch(:page, 1).to_i, 1].max
    limit  = [params.fetch(:limit, 25).to_i, 1].max
    offset = (page - 1) * limit

    events = DemandEvent.all

    # 1. Filtros directos de tabla
    events = events.where(id: params[:id]) if params[:id].present?
    events = events.where(idpk: params[:idpk]) if params[:idpk].present?
    events = events.where(event_type: params[:type]) if params[:type].present?

    # 2. RF4: Filtro por fecha de recepción (receivedAt)
    if params[:receivedAt].present?
      begin
        date = Date.parse(params[:receivedAt])
        events = events.where(received_at: date.all_day)
      rescue ArgumentError
        # Si el formato no es fecha válida, se ignora
      end
    end

    # 3. RF4: Filtro por validUntil (soporta texto exacto o prefijo de fecha YYYY-MM-DD)
    if params[:validUntil].present?
      val = params[:validUntil]
      # Coincide si es igual o si empieza con la fecha indicada
      events = events.where("package_body->>'validUntil' LIKE ?", "#{val}%")
    end

    # 4. RF4: Filtro por metaContent
    if params.key?(:metaContent)
      events = events.where("package_body->>'metaContent' = ?", params[:metaContent])
    end

    # 5. RF4: Filtro por constraints
    if params[:constraints].present?
      # Si viene como JSON string o valor plano, se evalúa con el operador @> o conversión a texto
      if params[:constraints].is_a?(ActionController::Parameters) || params[:constraints].is_a?(Hash)
        events = events.where("package_body->'constraints' @> ?", params[:constraints].to_unsafe_h.to_json)
      else
        begin
          parsed_constraints = JSON.parse(params[:constraints])
          events = events.where("package_body->'constraints' @> ?", parsed_constraints.to_json)
        rescue JSON::ParserError
          events = events.where("package_body->>'constraints' = ?", params[:constraints])
        end
      end
    end

    # 6. RF4: Filtros dentro del arreglo demands
    demand_filters = {}
    demand_filters[:city]   = params[:city]        if params[:city].present?
    demand_filters[:code]   = params[:code]        if params[:code].present?
    demand_filters[:unit]   = params[:unit]        if params[:unit].present?
    demand_filters[:demand] = params[:demand].to_f if params[:demand].present?

    if demand_filters.any?
      events = events.where("package_body->'demands' @> ?", [demand_filters].to_json)
    end

    total_records = events.count
    paginated_events = events.order(received_at: :desc).offset(offset).limit(limit)

    render json: {
      page: page,
      limit: limit,
      total: total_records,
      data: paginated_events.map { |e| format_event(e) }
    }, status: :ok
  end

  # RF2: Detalle por ID
  def show
    event = DemandEvent.find(params[:id])
    render json: format_event(event), status: :ok
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Not found' }, status: :not_found
  end

  private

  def format_event(event)
    {
      id: event.id,
      idpk: event.idpk,
      type: event.event_type,
      packageBody: event.package_body,
      receivedAt: event.received_at.iso8601
    }
  end
end
