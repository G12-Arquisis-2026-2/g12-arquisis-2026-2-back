# Mensaje que nuestro nodo quiere enviar a la central (patrón outbox).
# La API solo lo deja guardado aquí; el que lo publica en el broker es el connector.
class OutboxMessage < ApplicationRecord
  STATUSES = %w[pending sent failed].freeze

  validates :msg_id, presence: true, uniqueness: true
  validates :idpk, :message_type, :payload, presence: true
  validates :status, inclusion: { in: STATUSES }

  # Del más antiguo al más nuevo, para que salgan en el orden en que se crearon.
  scope :pending, -> { where(status: "pending").order(:id) }

  # Un negotiation-report que no alcanzó a salir antes del cierre de su ventana no se publica:
  # la central lo rechazaría con CYCLE_EXPIRED. Queda fallido (y el ciclo se registra como sin reporte).
  # Si no conocemos el ciclo no sabemos cuándo cierra, y se deja pasar.
  def self.expire_late_reports!(now = Time.current)
    where(status: "pending", message_type: "negotiation-report").find_each do |message|
      cycle = Cycle.find_by(cycle_id: message.payload["cycleId"])
      next unless cycle&.valid_until && now >= cycle.valid_until - CycleService::PUBLISH_MARGIN

      message.mark_failed!("CYCLE_WINDOW_CLOSED: la ventana de negociación cerró antes de publicarlo")
    end
  end

  def mark_sent!
    update!(status: "sent", sent_at: Time.current, error: nil, attempts: attempts + 1)
  end

  # Fallido = el connector decidió no publicarlo. No se vuelve a intentar.
  def mark_failed!(reason)
    update!(status: "failed", error: reason.to_s, attempts: attempts + 1)
  end
end
