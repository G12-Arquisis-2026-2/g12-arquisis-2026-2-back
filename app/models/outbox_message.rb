# Mensaje que nuestro nodo quiere enviar a la central (patrón outbox).
# La API solo lo deja guardado aquí; el que lo publica en el broker es el connector.
class OutboxMessage < ApplicationRecord
  STATUSES = %w[pending sent failed].freeze
  BID_REPLY_TYPES = %w[bid-accepted bid-rejected].freeze
  OFFER_TYPES = %w[offer offer-updated offer-withdrawn].freeze
  # Plazo de una reserva: si el relay muere sin marcar, la fila vuelve a estar disponible.
  CLAIM_TTL = 30.seconds

  validates :msg_id, presence: true, uniqueness: true
  validates :idpk, :message_type, :payload, presence: true
  validates :status, inclusion: { in: STATUSES }

  # Del más antiguo al más nuevo, para que salgan en el orden en que se crearon.
  scope :pending, -> { where(status: "pending").order(:id) }

  # Pendientes sin reserva vigente. Las del mismo relay se le devuelven (renueva la reserva), así no
  # esperan el plazo las que dejó para la otra vuelta (tope por minuto o un fallo).
  scope :claimable, lambda { |relay, now|
    where(status: "pending").where("locked_until IS NULL OR locked_until <= ? OR locked_by = ?", now, relay)
  }

  # Reserva hasta `limit` filas para `relay`. SKIP LOCKED: dos relays a la vez nunca toman la misma.
  # Primero las de la central (sin routing key), después el resto, cada grupo en orden de creación.
  def self.claim!(relay:, limit:, now: Time.current)
    transaction do
      rows = claimable(relay, now).order(Arel.sql("routing_key IS NULL DESC"), :id)
                                  .limit(limit).lock("FOR UPDATE SKIP LOCKED").to_a
      where(id: rows.map(&:id)).update_all(locked_by: relay, locked_until: now + CLAIM_TTL)
      rows
    end
  end

  # Última oferta nuestra que salió en el ciclo, para republicarla tras una reconexión.
  # nil si después salió un offer-withdrawn.
  def self.last_sent_offer(cycle_id)
    last = where(status: "sent", message_type: OFFER_TYPES)
           .where("payload ->> 'cycleId' = ?", cycle_id).order(:id).last
    last unless last.nil? || last.message_type == "offer-withdrawn"
  end

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

  # La última respuesta que dimos a ese bid. Una fallida no se repite: el connector no la publicó.
  def self.reply_to_bid(bid_idpk)
    where(reply_to_idpk: bid_idpk, message_type: BID_REPLY_TYPES).where.not(status: "failed").order(:id).last
  end

  def mark_sent!
    update!(status: "sent", sent_at: Time.current, error: nil, attempts: attempts + 1, locked_by: nil, locked_until: nil)
  end

  # Fallido = el connector decidió no publicarlo. No se vuelve a intentar.
  def mark_failed!(reason)
    update!(status: "failed", error: reason.to_s, attempts: attempts + 1, locked_by: nil, locked_until: nil)
  end
end
