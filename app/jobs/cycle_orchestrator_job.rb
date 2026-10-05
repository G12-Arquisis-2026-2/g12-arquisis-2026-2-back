class CycleOrchestratorJob < ApplicationJob
  queue_as :default

  def perform(cycle_id)
    Rails.logger.info "[CycleOrchestrator] Apertura de la ventana de 20 min para el ciclo #{cycle_id}"

    # 1. Verificar recepción de status-statement para el ciclo actual
    status_event = DemandEvent.find_by("package_body->>'cycleId' = ? AND event_type = ?", cycle_id, 'status-statement')

    unless status_event
      Rails.logger.warn "[CycleOrchestrator] status-statement no recibido. Emitiendo petición directa (type: request)..."
      city_id = ENV.fetch('CITY_ID', 'COR')
      request_payload = CycleService.build_direct_request(city_id)
      RabbitMQPublisher.publish(request_payload) if defined?(RabbitMQPublisher)
    end

    # 2. Programar negotiation-report 5 minutos antes del cierre
    NegotiationReportJob.set(wait: 15.minutes).perform_later(cycle_id)
  end
end