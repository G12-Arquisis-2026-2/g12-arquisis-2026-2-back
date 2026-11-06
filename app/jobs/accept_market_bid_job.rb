class AcceptMarketBidJob < ApplicationJob
  queue_as :default
  retry_on StandardError, wait: :polynomially_longer, attempts: 5

  def perform(target, message)
    bid = MarketBid.find_by(bid_msg_id: target)
    return unless bid&.side == "buy"
    return unless bid.status == "sent"

    cycle = Cycle.find_by(cycle_id: bid.cycle_id)
    if cycle&.market_closed_at || (cycle&.closes_at && Time.current >= cycle.closes_at)
      bid.update!(status: "timed_out")
      return
    end

    claims = WalletTokenValidator.verify!(message.dig("data", "swapToken"))
    unless valid_claims?(claims, bid, message)
      Rails.logger.error("[AcceptMarketBidJob] Token inválido para bid #{target}; no se acepta el swap.")
      bid.update!(status: "rejected")
      MarketCycleJob.perform_later(bid.cycle_id)
      return
    end

    accept_idpk = SecureRandom.uuid
    MarketBid.transaction do
      bid.lock!
      return unless bid.status == "sent"

      bid.update!(
        status: "accepting",
        swap_id: message.dig("data", "swapId"),
        accept_idpk: accept_idpk,
        expires_at: message.dig("data", "expiresAt")
      )
      SwapIntention.create!(
        idpk: accept_idpk,
        swap_id: bid.swap_id,
        give_amount: bid.quantity,
        take_amount: bid.amount,
        expires_at: bid.expires_at,
        status: :pending
      )
    end

    result = WalletClient.new.accept_swap(swap_id: bid.swap_id, idempotency_key: accept_idpk)
    return if result.success? || result.retry_required?

    bid.update!(status: "rejected")
    SwapIntention.find_by(idpk: accept_idpk)&.update!(status: :rejected)
    MarketCycleJob.perform_later(bid.cycle_id)
  end

  private

  def valid_claims?(claims, bid, message)
    return false unless claims.is_a?(Hash)
    return false unless claims["sub"] == message.dig("data", "swapId")
    return false unless claims["proposer"] == bid.seller_city
    return false unless claims["memo"] == bid.offer_id
    return false unless claims["exp"].is_a?(Numeric) && claims["exp"] > Time.current.to_i

    amount_of(claims["give"], "KWH") == bid.quantity &&
      amount_of(claims["take"], "CR") == bid.amount.to_d &&
      message.dig("data", "offerId") == bid.offer_id &&
      message.dig("data", "quantity") == bid.quantity &&
      message.dig("data", "pricePerEnergy").to_d == bid.price_per_energy.to_d &&
      message.dig("data", "amount").to_d == bid.amount.to_d &&
      Time.iso8601(message.dig("data", "expiresAt")) > Time.current
  rescue ArgumentError, TypeError
    false
  end

  def amount_of(asset_claim, expected_asset)
    return unless asset_claim.is_a?(Hash) && asset_claim["asset"] == expected_asset

    asset_claim["amount"].to_d
  end
end
