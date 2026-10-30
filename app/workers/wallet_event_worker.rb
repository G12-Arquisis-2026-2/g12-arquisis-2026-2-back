require "json"

class WalletEventWorker
  def self.perform(payload)
    new.perform(payload)
  end

  def perform(payload)
    event = payload.is_a?(Hash) ? payload : JSON.parse(payload)

    case event["type"]
    when "swap-proposed"
      handle_proposed(event)
    when "swap-settled"
      reconcile(event, :settled)
    when "swap-rejected"
      reconcile(event, :rejected)
    when "swap-cancelled"
      reconcile(event, :cancelled)
    when "swap-expired"
      reconcile(event, :expired)
    else
      Rails.logger.warn("[WalletEventWorker] Evento desconocido: #{event['type'].inspect}")
    end
  rescue JSON::ParserError => error
    Rails.logger.error("[WalletEventWorker] Payload JSON inválido: #{error.message}")
  end

  private

  def handle_proposed(event)
    token = event.dig("data", "token")
    claims = WalletTokenValidator.verify!(token)
    return false unless claims

    swap_id = claims["sub"]
    proposer = claims["proposer"]
    give = claims["give"]
    take = claims["take"]

    SwapIntention.find_or_create_by!(idpk: event.dig("data", "idpk")) do |intention|
      intention.swap_id = swap_id
      intention.give_amount = give
      intention.take_amount = take
      intention.expires_at = Time.at(claims.fetch("exp"))
      intention.status = :pending
    end

    Rails.logger.info("[WalletEventWorker] Swap #{swap_id} proposed by #{proposer}")
    true
  end

  def reconcile(event, status)
    idpk = event.dig("data", "idpk")
    return if idpk.blank?

    SwapIntention.find_by(idpk: idpk)&.update!(status: status)
  end
end
