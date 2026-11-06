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
    data = event.fetch("data")
    claims = WalletTokenValidator.verify!(data.fetch("token"))
    return false unless claims

    idpk = data.fetch("idpk")
    swap_id = claims["sub"] || data["swapId"]
    intention = SwapIntention.find_by(swap_id: swap_id) if swap_id.present?
    intention ||= SwapIntention.find_or_initialize_by(idpk: idpk)
    intention.swap_id ||= swap_id
    intention.cycle_id ||= event["cycleId"]
    intention.give_amount = nested_amount(claims["give"], data.dig("give", "amount"))
    intention.take_amount = nested_amount(claims["take"], data.dig("take", "amount"))
    intention.expires_at = Time.at(claims.fetch("exp"))
    return false if intention.persisted? && %w[settled rejected cancelled expired].include?(intention.status)

    intention.status = :pending
    intention.save!

    Rails.logger.info("[WalletEventWorker] Swap #{swap_id} proposed by #{claims['proposer']}")
    true
  end

  def reconcile(event, status)
    data = event.fetch("data")
    idpk = data["idpk"] || event["idpk"] || data["swapId"]
    return false if idpk.blank?

    swap_id = data["swapId"]
    intention = SwapIntention.find_by(swap_id: swap_id) if swap_id.present?
    intention ||= SwapIntention.find_by(idpk: data["idpk"])
    intention ||= SwapIntention.find_or_initialize_by(idpk: idpk)

    intention.swap_id ||= swap_id
    intention.cycle_id ||= data["cycleId"] || event["cycleId"]
    intention.give_amount = nested_amount(data["give"], 0) if intention.give_amount.blank?
    intention.take_amount = nested_amount(data["take"], 0) if intention.take_amount.blank?
    return false if %w[settled rejected cancelled expired].include?(intention.status)

    intention.status = status
    intention.save!
    true
  end

  def nested_amount(value, fallback = nil)
    if value.is_a?(Hash)
      value["quantity"] || value["amount"] || fallback
    else
      value || fallback
    end
  end
end
