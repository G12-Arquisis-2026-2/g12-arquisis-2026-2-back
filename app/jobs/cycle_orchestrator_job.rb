class CycleOrchestratorJob < ApplicationJob
  queue_as :default

  limits_of concurrency: 1, key: "cycle_orchestrator_single_instance"

  def perform
    now = Time.current

    # Buscar el status-statement más reciente en la BD
    latest_status = DemandEvent.where(event_type: 'status-statement')
                               .order(created_at: :desc)
                               .first

    valid_until = extract_valid_until(latest_status)
    cycle_id = extract_cycle_id(latest_status)

    # --------------------------------------------------------------------------
    # CASO 0: No hay ningún status-statement registrado (Arranque en frío / inicio)
    # --------------------------------------------------------------------------
    if valid_until.nil?
      Rails.logger.warn "[CycleOrchestrator] No existe status-statement en BD. Solicitando a la central..."
      request_status_from_broker
      CycleOrchestratorJob.set(wait: 30.seconds).perform_later
      return
    end

    window_start = valid_until - 20.minutes
    window_end   = valid_until
    next_window  = valid_until + 1.hour + 40.minutes

    # CASO 1: Estamos DENTRO de la ventana de negociación del statement activo
    if now >= window_start && now < window_end
      Rails.logger.info "[CycleOrchestrator] Ventana activa para el ciclo #{cycle_id}. (Expira: #{valid_until})"

      report_time = valid_until - 5.minutes

      if now < report_time
        Rails.logger.info "[CycleOrchestrator] Programando NegotiationReportJob para: #{report_time}"
        NegotiationReportJob.set(wait_until: report_time).perform_later(cycle_id)
      else
        Rails.logger.warn "[CycleOrchestrator] En periodo de cierre (últimos 5 min). Ejecutando NegotiationReportJob inmediatamente."
        NegotiationReportJob.perform_later(cycle_id)
      end

      # Programar el despertador para el inicio exacto de la SIGUIENTE ventana
      Rails.logger.info "[CycleOrchestrator] Próxima ventana inicia a las: #{next_window}"
      CycleOrchestratorJob.set(wait_until: next_window).perform_later

    # CASO 2: Ya abrió la siguiente ventana, pero NO nos ha llegado el nuevo status-statement
    elsif now >= next_window
      Rails.logger.warn "[CycleOrchestrator] Deberíamos estar en negociación del próximo ciclo, pero no hay nuevo status-statement. Solicitando..."
      request_status_from_broker

      # Reintentar en 30 segundos a la espera de que el connector reciba el nuevo statement
      CycleOrchestratorJob.set(wait: 30.seconds).perform_later

    # CASO 3: Estamos en periodo de consumo fuera de la ventana de negociación
    else
      Rails.logger.info "[CycleOrchestrator] En periodo de consumo. Durmiendo hasta la próxima ventana: #{next_window}"
      CycleOrchestratorJob.set(wait_until: next_window).perform_later
    end
  end

  private

  def request_status_from_broker
    request_payload = CycleService.build_direct_request(ask: 'status-statement')
    RabbitMQPublisher.publish(request_payload) if defined?(RabbitMQPublisher)
  end

  def extract_valid_until(event)
    return nil unless event

    raw_date = event.package_body.dig('data', 'validUntil') || event.package_body['validUntil']
    Time.parse(raw_date) rescue nil
  end

  def extract_cycle_id(event)
    return nil unless event

    event.package_body['cycleId'] || event.package_body.dig('data', 'cycleId')
  end
end