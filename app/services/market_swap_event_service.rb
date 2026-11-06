class MarketSwapEventService
  class InvalidWalletEvent < StandardError; end

  def self.call(event)
    new(event).call
  end

  def initialize(event)
    @event = event
    @data = event.fetch("data")
  end

  def call
    case @event.fetch("type")
    when "swap-proposed" then proposed
    when "swap-settled" then settled
    when "swap-rejected" then rejected
    when "swap-cancelled", "swap-expired" then released
    end
  end

  private

  def proposed
    bid = MarketBid.find_by(proposal_idpk: @data.fetch("idpk"))
    return true unless bid

    claims = WalletTokenValidator.verify!(@data.fetch("token"))
    unless valid_proposal_token?(claims, bid)
      raise InvalidWalletEvent, "Token inválido en swap-proposed para bid #{bid.bid_idpk}"
    end

    expires_at = Time.iso8601(@data.fetch("expiresAt"))
    MarketBid.transaction do
      bid.lock!
      return true unless bid.status == "proposing"

      bid.update!(status: "proposed", swap_id: @data.fetch("swapId"), expires_at: expires_at)
      publish_bid_accepted(bid, @data.fetch("token"), expires_at)
      publish_offer_update(bid)
    end
    SwapIntention.find_by(idpk: bid.proposal_idpk)&.update!(swap_id: bid.swap_id, expires_at: expires_at)
    true
  end

  def settled
    bid = MarketBid.find_by(swap_id: @data.fetch("swapId"))
    update_intention(:settled)
    return true unless bid

    MarketBid.transaction do
      bid.lock!
      return true if bid.status == "settled"

      bid.update!(status: "settled")
      if bid.side == "sell"
        offer = MarketOffer.find_by(cycle_id: bid.cycle_id, city_id: bid.seller_city, offer_id: bid.offer_id)
        offer&.with_lock do
          offer.update!(
            remaining: [offer.remaining - bid.quantity, 0].max,
            reserved_quantity: [offer.reserved_quantity - bid.quantity, 0].max
          )
        end
        publish_offer_update(bid) if offer
      end
    end
    MarketCycleJob.perform_later(bid.cycle_id)
    true
  end

  def rejected
    idpk = @data["idpk"]
    bid = MarketBid.find_by(proposal_idpk: idpk) || MarketBid.find_by(accept_idpk: idpk)
    update_intention(:rejected, idpk:)
    return true unless bid

    if bid.side == "sell"
      release_seller_reservation(bid)
      publish_bid_rejected(bid)
      publish_offer_update(bid)
    else
      bid.update!(status: "rejected")
      MarketCycleJob.perform_later(bid.cycle_id)
    end
    true
  end

  def released
    bid = MarketBid.find_by(swap_id: @data.fetch("swapId"))
    final_status = @event.fetch("type") == "swap-expired" ? :expired : :cancelled
    update_intention(final_status)
    return true unless bid

    if bid.side == "sell"
      release_seller_reservation(bid, final_status.to_s)
      publish_offer_update(bid)
    else
      bid.update!(status: final_status.to_s)
      MarketCycleJob.perform_later(bid.cycle_id)
    end
    true
  end

  def valid_proposal_token?(claims, bid)
    return false unless claims.is_a?(Hash)
    return false unless claims["sub"] == @data["swapId"] && claims["proposer"] == ENV.fetch("CITY_ID", "TK3")
    return false unless claims["memo"] == bid.offer_id
    return false unless amount_of(claims["give"], "KWH") == bid.quantity.to_d
    return false unless amount_of(claims["take"], "CR") == bid.amount.to_d

    claims["exp"].is_a?(Numeric) && claims["exp"] > Time.current.to_i
  end

  def amount_of(value, asset)
    return unless value.is_a?(Hash) && value["asset"] == asset

    value["amount"].to_d
  end

  def publish_bid_accepted(bid, token, expires_at)
    RabbitMQPublisher.publish(
      {
        type: "bid-accepted",
        cycleId: bid.cycle_id,
        data: {
          target: bid.bid_msg_id,
          offerId: bid.offer_id,
          quantity: bid.quantity,
          pricePerEnergy: bid.price_per_energy,
          amount: bid.amount,
          swapId: bid.swap_id,
          swapToken: token,
          expiresAt: expires_at.iso8601
        }
      },
      to_city: bid.buyer_city
    )
  end

  def publish_bid_rejected(bid)
    available = MarketOffer.find_by(cycle_id: bid.cycle_id, city_id: bid.seller_city, offer_id: bid.offer_id)
                             &.then { |offer| [offer.remaining - offer.reserved_quantity, 0].max } || 0
    reason = @event["reason"] == "MARKET_CLOSED" ? "MARKET_CLOSED" : "QUANTITY_UNAVAILABLE"
    RabbitMQPublisher.publish(
      {
        type: "bid-rejected",
        cycleId: bid.cycle_id,
        reason: reason,
        code: reason == "MARKET_CLOSED" ? 410 : 409,
        data: {
          target: bid.bid_msg_id,
          offerId: bid.offer_id,
          requested: bid.quantity
        }
          .tap { |data| data[:available] = available if reason == "QUANTITY_UNAVAILABLE" }
      },
      to_city: bid.buyer_city
    )
  end

  def publish_offer_update(bid)
    offer = MarketOffer.find_by(cycle_id: bid.cycle_id, city_id: bid.seller_city, offer_id: bid.offer_id)
    return unless offer

    RabbitMQPublisher.publish(
      {
        type: "offer-updated",
        cycleId: bid.cycle_id,
        data: {
          offerId: offer.offer_id,
          remaining: [offer.remaining - offer.reserved_quantity, 0].max,
          pricePerEnergy: offer.price_per_energy
        }
      },
      to_market: true
    )
  end

  def release_seller_reservation(bid, status = "rejected")
    MarketBid.transaction do
      bid.lock!
      return if %w[rejected cancelled expired settled].include?(bid.status)

      offer = MarketOffer.find_by(cycle_id: bid.cycle_id, city_id: bid.seller_city, offer_id: bid.offer_id)
      offer&.with_lock do
        offer.update!(reserved_quantity: [offer.reserved_quantity - bid.quantity, 0].max)
      end
      bid.update!(status: status)
    end
  end

  def update_intention(status, idpk: nil)
    intention = if idpk.present?
      SwapIntention.find_by(idpk: idpk)
    else
      SwapIntention.find_by(swap_id: @data["swapId"])
    end
    intention&.update!(status: status)
  end
end
