# Mensaje que nuestro nodo quiere enviar a la central (patrón outbox).
# La API solo lo deja guardado aquí; el que lo publica en el broker es el connector.
class OutboxMessage < ApplicationRecord
  STATUSES = %w[pending sent failed].freeze

  validates :msg_id, presence: true, uniqueness: true
  validates :idpk, :message_type, :payload, presence: true
  validates :status, inclusion: { in: STATUSES }

  # Del más antiguo al más nuevo, para que salgan en el orden en que se crearon.
  scope :pending, -> { where(status: "pending").order(:id) }

  def mark_sent!
    update!(status: "sent", sent_at: Time.current, error: nil, attempts: attempts + 1)
  end

  # Fallido = el connector decidió no publicarlo. No se vuelve a intentar.
  def mark_failed!(reason)
    update!(status: "failed", error: reason.to_s, attempts: attempts + 1)
  end
end
