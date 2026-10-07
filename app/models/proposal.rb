class Proposal < ApplicationRecord
  # Enunciado § Pago: quien recibe el pago (give) espera el transfer 30 s después de la confirmación.
  # Si no llega, reintenta la operación con el mismo idpk, hasta MAX_TRANSFER_RETRIES veces.
  TRANSFER_WAIT = 30.seconds
  MAX_TRANSFER_RETRIES = 3

  validates :idpk, presence: true, uniqueness: true
  validates :cycle_id, :direction, :quantity, :generation_cost, :status, presence: true

  # Estados definidos en ADR3. Los cerrados sin operación:
  #   expired:  sin confirmación hasta que cerró la ventana del ciclo (expirada por timeout, RF04)
  #   rejected: la central respondió un error (PRICE_ABOVE_CAP, OVER_CAPACITY, CYCLE_EXPIRED, CYCLE_UNKNOWN)
  #   failed:   no se pudo armar el reintento, o un give confirmado nunca recibió su transfer
  enum :status, {
    pending: 'PENDING',
    confirmed: 'CONFIRMED',
    paid: 'PAID',
    timeout: 'TIMEOUT',
    expired: 'EXPIRED',
    rejected: 'REJECTED',
    failed: 'FAILED'
  }, default: 'PENDING'

  # El ledger confirma con update!(status: "CONFIRMED"): aquí se registra cuándo, sin tocar el ledger.
  # Solo al pasar a CONFIRMED (una reconfirmación no cambia el estado y no agenda otra espera).
  before_save :stamp_confirmed_at, if: -> { will_save_change_to_status? && confirmed? }
  after_commit :schedule_transfer_wait, if: -> { saved_change_to_status? && confirmed? && give? }

  def give?
    direction.to_s == "give"
  end

  # Cierra una propuesta que sigue abierta (por defecto, pendiente) y anula sus reintentos que aún no
  # salieron del outbox, para que no se vuelva a publicar. Devuelve false si ya estaba en otro estado
  # (no la pisa).
  def close!(new_status, reason, from: :pending)
    with_lock do
      next false unless Array(from).map(&:to_s).include?(status)

      update!(status: new_status, status_reason: reason.to_s.truncate(255))
      OutboxMessage.where(idpk: idpk, message_type: "negotiation-proposal", status: "pending")
                   .find_each { |message| message.mark_failed!("PROPOSAL_#{status.upcase}: #{status_reason}") }
      true
    end
  end

  # Desde cuándo corre la espera actual del transfer: la confirmación o el último reintento.
  def transfer_due_at
    (last_transfer_retry_at || confirmed_at || updated_at) + TRANSFER_WAIT
  end

  # El transfer de pago llegó: el ledger ya la marcó PAID, o hay un transfer cuyo becauseOf es el msgId
  # de una confirmación give dirigida a alguno de nuestros mensajes de esta propuesta (mismo idpk).
  def transfer_received?
    return true if paid?

    proposal_msg_ids = OutboxMessage.where(idpk: idpk, message_type: "negotiation-proposal").pluck(:msg_id)
    confirmation_msg_ids = Transaction.where(operation_type: "give")
                                      .where("raw_data->'data'->>'target' IN (?)", proposal_msg_ids + [idpk])
                                      .pluck(Arel.sql("raw_data->>'msgId'")).compact
    return false if confirmation_msg_ids.empty?

    Transaction.where(operation_type: "transfer")
               .where("raw_data->'data'->>'becauseOf' IN (?)", confirmation_msg_ids)
               .exists?
  end

  private

  def stamp_confirmed_at
    self.confirmed_at ||= Time.current
  end

  def schedule_transfer_wait
    NegotiationTimeoutJob.set(wait_until: transfer_due_at)
                         .perform_later(idpk, transfer_attempt: transfer_retries)
  end
end
