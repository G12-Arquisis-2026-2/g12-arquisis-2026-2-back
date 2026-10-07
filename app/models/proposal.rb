class Proposal < ApplicationRecord
  validates :idpk, presence: true, uniqueness: true
  validates :cycle_id, :direction, :quantity, :generation_cost, :status, presence: true

  # Estados definidos en ADR3. Los cerrados sin operación:
  #   expired:  sin confirmación hasta que cerró la ventana del ciclo (expirada por timeout, RF04)
  #   rejected: la central respondió un error (PRICE_ABOVE_CAP, OVER_CAPACITY, CYCLE_EXPIRED, CYCLE_UNKNOWN)
  #   failed:   no se pudo armar el reintento
  enum :status, {
    pending: 'PENDING',
    confirmed: 'CONFIRMED',
    paid: 'PAID',
    timeout: 'TIMEOUT',
    expired: 'EXPIRED',
    rejected: 'REJECTED',
    failed: 'FAILED'
  }, default: 'PENDING'

  # Cierra una propuesta que sigue pendiente y anula sus reintentos que aún no salieron del outbox,
  # para que no se vuelva a publicar. Devuelve false si ya estaba resuelta (no la pisa).
  def close!(new_status, reason)
    with_lock do
      next false unless pending?

      update!(status: new_status, status_reason: reason.to_s.truncate(255))
      OutboxMessage.where(idpk: idpk, message_type: "negotiation-proposal", status: "pending")
                   .find_each { |message| message.mark_failed!("PROPOSAL_#{status.upcase}: #{status_reason}") }
      true
    end
  end
end
