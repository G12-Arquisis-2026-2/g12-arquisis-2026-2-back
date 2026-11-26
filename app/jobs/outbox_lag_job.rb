# Cada 15 s (config/recurring.yml) envía a New Relic el atraso del outbox (ADR8): la alerta
# "Outbox con atraso" usa la edad de la fila pendiente más antigua.
class OutboxLagJob < ApplicationJob
  EVENT_TYPE = "OutboxLag".freeze

  queue_as :default
  # Si una corrida sigue en curso, la siguiente se descarta en vez de esperar: nunca se acumulan.
  limits_concurrency key: ->(*) { "outbox_lag" }, duration: 1.minute, on_conflict: :discard

  def perform
    lag = OutboxMessage.lag
    sent = report(lag)
    Rails.logger.info("[OutboxLag] #{lag.map { |name, value| "#{name}=#{value}" }.join(' ')} new_relic=#{sent}")
  end

  private

  # Corre en el worker de Solid Queue (proceso hijo de Puma): el agente reabre ahí su hilo de envío al
  # empezar la transacción del job. "registrado" = quedó en el buffer del agente; llega a New Relic solo si
  # el agente está conectado (en un worker recién creado conecta en segundo plano y sale en el envío siguiente).
  def report(lag)
    return "inactivo" unless agent_started?

    NewRelic::Agent.record_custom_event(EVENT_TYPE, event_attributes(lag))
    NewRelic::Agent.agent.connected? ? "registrado,conectado" : "registrado,sin_conexion"
  rescue StandardError => e
    "error:#{e.class}"
  end

  def agent_started?
    defined?(NewRelic::Agent) && NewRelic::Agent.agent&.started? && NewRelic::Agent.config[:agent_enabled]
  end

  def event_attributes(lag)
    lag.merge(cityId: ENV.fetch("CITY_ID", "TK3"))
  end
end
