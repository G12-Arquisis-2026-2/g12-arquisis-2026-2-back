# Opera el ciclo sin intervención manual (G03): pide el status-statement si no llegó y emite el
# negotiation-report en el periodo de cierre. Cada ejecución revisa el estado (CycleService.tick)
# y se vuelve a programar para cuando toque, aunque la revisión falle: la cadena no se corta.
class CycleOrchestratorJob < ApplicationJob
  queue_as :default

  # Si el tick revienta (ej: BD caída un momento) se reintenta en este rato.
  ERROR_RETRY = 1.minute
  # Advisory lock de Postgres: dos cadenas (o dos procesos) nunca revisan a la vez.
  LOCK_KEY = 2_173_003

  # Arranca la cadena salvo que ya haya una ejecución pendiente o programada (un reinicio no duplica).
  def self.start_chain
    if already_scheduled?
      Rails.logger.info "[CycleOrchestrator] Ya hay una ejecución pendiente, no se encola otra."
      return false
    end

    Rails.logger.info "[CycleOrchestrator] Encolando el primer CycleOrchestratorJob."
    perform_later
    true
  end

  # Solo Solid Queue (producción) guarda los jobs en la BD y sobrevive a un reinicio. Los fallidos
  # también quedan con finished_at nulo, por eso se excluyen: si no, un crash dejaría la cadena muerta.
  # Con el adaptador async (desarrollo) la cola vive en memoria y un reinicio la vacía.
  def self.already_scheduled?
    return false unless queue_adapter_name.to_s == "solid_queue"

    SolidQueue::Job.where(class_name: name, finished_at: nil).where.missing(:failed_execution).exists?
  end

  def perform
    wake_at = ApplicationRecord.transaction do
      ApplicationRecord.connection.execute("SELECT pg_advisory_xact_lock(#{LOCK_KEY})")
      CycleService.tick(Time.current)
    end
  rescue StandardError => e
    Rails.logger.error "[CycleOrchestrator] Falló la revisión (#{e.class}: #{e.message}). Reintento en #{ERROR_RETRY.inspect}."
    wake_at = ERROR_RETRY.from_now
  ensure
    self.class.set(wait_until: wake_at || ERROR_RETRY.from_now).perform_later
  end
end
