class SellMarketBidJob < ApplicationJob
  queue_as :default

  REJECTION_CODES = {
    "QUANTITY_UNAVAILABLE" => 409,
    "OFFER_WITHDRAWN" => 410,
    "BID_TOO_SMALL" => 422,
    "MARKET_CLOSED" => 410,
    "SELF_TRADE" => 422
  }.freeze

  def perform(bid_idpk)
    bid = MarketBid.find_by!(bid_idpk: bid_idpk)
    offer = nil
    rejection = nil

    MarketBid.transaction do
      bid.lock!
      return if bid.status != "pending"

      cycle = Cycle.find_by(cycle_id: bid.cycle_id)
      offer = MarketOffer.find_by(
        cycle_id: bid.cycle_id,
        city_id: ENV.fetch("CITY_ID", "TK3"),
        offer_id: bid.offer_id
      )

      if cycle.nil? || offer.nil? || !offer.active?
        rejection = "OFFER_WITHDRAWN"
      else
        offer.lock!
        rejection = NegotiationStrategyService.bid_rejection_reason(
          cycle: cycle,
          offer_id: offer.offer_id,
          bid: bid.raw_payload,
          remaining: offer.remaining - offer.reserved_quantity
        )
        if rejection.nil?
          unless reserve!(bid, offer, cycle)
            rejection = "MARKET_CLOSED"
            bid.update!(status: "rejected")
          end
        else
          bid.update!(status: "rejected")
        end
      end
    end

    return publish_rejection(bid, rejection, offer) if rejection

    result = WalletClient.new.propose_swap(
      give: { asset: "KWH", amount: bid.quantity },
      take: { asset: "CR", amount: bid.amount },
      memo: bid.offer_id,
      expires_at: bid.expires_at.iso8601,
      idempotency_key: bid.proposal_idpk
    )
    return if result.success? || result.retry_required?

    release_reservation!(bid)
    publish_rejection(bid, "QUANTITY_UNAVAILABLE", offer)
  end

  private

  def reserve!(bid, offer, cycle)
    now = Time.current
    price = offer.price_per_energy.to_d
    amount = (bid.quantity * price).round(2)
    expires_at = [now + 60.seconds, cycle.closes_at].compact.min
    return false if expires_at <= now

    proposal_idpk = SecureRandom.uuid
    bid.update!(
      status: "proposing",
      price_per_energy: price,
      amount: amount,
      proposal_idpk: proposal_idpk,
      expires_at: expires_at
    )
    offer.update!(reserved_quantity: offer.reserved_quantity + bid.quantity)
    RabbitMQPublisher.publish(
      {
        type: "offer-updated",
        cycleId: cycle.cycle_id,
        data: {
          offerId: offer.offer_id,
          remaining: offer.remaining - offer.reserved_quantity,
          pricePerEnergy: offer.price_per_energy
        }
      },
      to_market: true
    )
    SwapIntention.create!(
      idpk: proposal_idpk,
      give_amount: bid.quantity,
      take_amount: amount,
      expires_at: expires_at,
      status: :pending
    )
    true
  end

  def release_reservation!(bid)
    MarketBid.transaction do
      bid.lock!
      offer = MarketOffer.find_by(cycle_id: bid.cycle_id, city_id: bid.seller_city, offer_id: bid.offer_id)
      offer&.with_lock do
        offer.update!(reserved_quantity: [offer.reserved_quantity - bid.quantity, 0].max)
      end
      bid.update!(status: "rejected")
      SwapIntention.find_by(idpk: bid.proposal_idpk)&.update!(status: :rejected)
    end
    publish_offer_update(bid)
  end

  def publish_rejection(bid, reason, offer)
    reason ||= "OFFER_WITHDRAWN"
    data = {
      target: bid.bid_msg_id,
      offerId: bid.offer_id,
      requested: bid.quantity
    }
    data[:available] = [offer.remaining - offer.reserved_quantity, 0].max if reason == "QUANTITY_UNAVAILABLE"
    RabbitMQPublisher.publish(
      {
        type: "bid-rejected",
        cycleId: bid.cycle_id,
        reason: reason,
        code: REJECTION_CODES.fetch(reason),
        data: data
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
end
