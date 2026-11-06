class MarketMessageProcessor
  def self.call(payload)
    processed = ProcessedMessage.process_once(payload) { new(payload).call }
    resend_bid_reply(payload) if !processed && payload["type"] == "bid"
    processed
  end

  # Bid repetido: se reenvía la respuesta que ya dimos (anomalía 1). Si falla solo se loguea,
  # porque un 500 trabaría la cola del connector.
  def self.resend_bid_reply(payload)
    RabbitMQPublisher.resend_bid_reply(payload)
  rescue StandardError => e
    Rails.logger.error("[MarketMessageProcessor] No se pudo reenviar la respuesta al bid #{payload['idpk']} (#{e.class}: #{e.message})")
  end

  def initialize(payload)
    @payload = payload
    @data = payload.fetch("data")
  end

  def call
    case @payload.fetch("type")
    when "offer"
      save_offer(quantity: @data.fetch("quantity"), remaining: @data.fetch("quantity"))
    when "offer-updated"
      save_offer(quantity: @data.fetch("remaining"), remaining: @data.fetch("remaining"))
    when "offer-withdrawn"
      withdraw_offer
    when "bid"
      save_bid
    when "bid-accepted"
      AcceptMarketBidJob.perform_later(@data.fetch("target"), @payload)
    when "bid-rejected"
      reject_bid
    when "market-closed"
      close_market
    when "swap-proposed", "swap-settled", "swap-rejected", "swap-cancelled", "swap-expired"
      MarketSwapEventService.call(@payload)
    when "trade-recorded", "imbalance-settlement"
      true
    end
  end

  private

  def save_offer(quantity:, remaining:)
    offer = MarketOffer.find_or_initialize_by(
      cycle_id: @payload.fetch("cycleId"),
      city_id: @payload.fetch("cityId"),
      offer_id: @data.fetch("offerId")
    )
    remaining = remaining.to_i + offer.reserved_quantity if offer.local?
    offer.assign_attributes(
      quantity: [offer.quantity.to_i, quantity.to_i].max,
      remaining: remaining,
      price_per_energy: @data.fetch("pricePerEnergy"),
      active: true,
      raw_payload: @payload
    )
    offer.save!
    MarketCycleJob.perform_later(offer.cycle_id)
    offer
  end

  def withdraw_offer
    MarketOffer.find_by(
      cycle_id: @payload.fetch("cycleId"),
      city_id: @payload.fetch("cityId"),
      offer_id: @data.fetch("offerId")
    )&.update!(active: false, remaining: 0, raw_payload: @payload)
    true
  end

  def save_bid
    MarketBid.create!(
      cycle_id: @payload.fetch("cycleId"),
      offer_id: @data.fetch("offerId"),
      bid_idpk: @payload.fetch("idpk"),
      bid_msg_id: @payload.fetch("msgId"),
      side: "sell",
      buyer_city: @payload.fetch("cityId"),
      seller_city: ENV.fetch("CITY_ID", "TK3"),
      quantity: @data.fetch("quantity"),
      status: "pending",
      raw_payload: @payload
    )
    SellMarketBidJob.perform_later(@payload.fetch("idpk"))
  end

  def reject_bid
    bid = MarketBid.find_by(bid_msg_id: @data.fetch("target"))
    return true unless bid

    bid.update!(status: "rejected")
    if @payload["reason"] == "QUANTITY_UNAVAILABLE" && @data["available"]
      MarketOffer.find_by(cycle_id: bid.cycle_id, city_id: bid.seller_city, offer_id: bid.offer_id)
                 &.update!(remaining: @data.fetch("available"))
    elsif @payload["reason"] == "OFFER_WITHDRAWN"
      MarketOffer.find_by(cycle_id: bid.cycle_id, city_id: bid.seller_city, offer_id: bid.offer_id)
                 &.update!(active: false, remaining: 0)
    end
    MarketCycleJob.perform_later(bid.cycle_id)
    true
  end

  def close_market
    Cycle.find_by(cycle_id: @payload.fetch("cycleId"))&.update!(market_closed_at: Time.current)
    MarketOffer.where(cycle_id: @payload.fetch("cycleId")).update_all(active: false, remaining: 0)
    true
  end
end
