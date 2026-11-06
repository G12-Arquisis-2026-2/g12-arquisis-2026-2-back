class MarketCycleJob < ApplicationJob
  queue_as :default

  def perform(cycle_id)
    cycle = Cycle.find_by(cycle_id: cycle_id)
    return unless cycle&.market_strategy_id && cycle.closes_at
    return if cycle.market_closed_at

    now = Time.current
    return schedule_at(cycle, cycle.market_opens_at) if cycle.market_opens_at && now < cycle.market_opens_at
    return if now >= cycle.closes_at

    strategy = cycle.market_strategy
    schedule_at(cycle, [now + strategy.span_seconds.seconds, cycle.closes_at].min)
    maintain_offer(cycle, strategy, now) if cycle.last_offer_at.nil? || now < cycle.last_offer_at
    send_best_bid(cycle, strategy, now) if cycle.last_bid_at.nil? || now < cycle.last_bid_at
  rescue StandardError => error
    Rails.logger.error("[MarketCycleJob] Falló el ciclo #{cycle_id} (#{error.class}: #{error.message})")
    raise
  end

  private

  def maintain_offer(cycle, strategy, now)
    return if cycle.sellable.to_i <= 0

    wallet_kwh = available_wallet_kwh
    offer_id = "#{ENV.fetch('CITY_ID', 'TK3')}-#{cycle.cycle_id}"
    offer = MarketOffer.lock.find_or_initialize_by(
      cycle_id: cycle.cycle_id,
      city_id: ENV.fetch("CITY_ID", "TK3"),
      offer_id: offer_id
    )
    remaining = [cycle.sellable - settled_sales(cycle), wallet_kwh + offer.reserved_quantity.to_i].min
    remaining = [remaining, 0].max
    offer_payload = NegotiationStrategyService.build_offer(
      cycle: cycle,
      offer_id: offer_id,
      quantity: remaining,
      strategy: strategy,
      now: now
    )
    return unless offer_payload

    price = offer_payload.dig(:data, :pricePerEnergy)
    if offer.new_record?
      offer.assign_attributes(
        quantity: remaining,
        remaining: remaining,
        reserved_quantity: 0,
        price_per_energy: price,
        active: remaining.positive?,
        raw_payload: offer_payload
      )
      offer.save!
      RabbitMQPublisher.publish(offer_payload, to_market: true) if remaining.positive?
    elsif offer.remaining != remaining || offer.price_per_energy != price
      offer.update!(remaining: remaining, quantity: [offer.quantity, remaining].max, price_per_energy: price)
      RabbitMQPublisher.publish(
        {
          type: "offer-updated",
          cycleId: cycle.cycle_id,
          data: { offerId: offer_id, remaining: remaining - offer.reserved_quantity, pricePerEnergy: price }
        },
        to_market: true
      )
    end
  end

  def send_best_bid(cycle, strategy, now)
    timeout_unanswered_bids(cycle, now)
    needed = remaining_deficit(cycle)
    return if needed <= 0
    return if MarketBid.unresolved_buy(cycle.cycle_id).exists?

    offers = MarketOffer.available.where(cycle_id: cycle.cycle_id).where.not(city_id: ENV.fetch("CITY_ID", "TK3"))
    candidate = NegotiationStrategyService.best_buy_bid(
      cycle: cycle,
      offers: offers.map { |offer| offer_attributes(offer) },
      distances: DistanceTable.all.index_by(&:destination_code),
      energy_needed: needed,
      strategy: strategy,
      now: now
    )
    return unless candidate

    message_id = RabbitMQPublisher.publish(candidate[:payload], to_city: candidate[:city_id])
    outbox = OutboxMessage.find_by!(msg_id: message_id)
    MarketBid.create!(
      cycle_id: cycle.cycle_id,
      offer_id: candidate[:offer_id],
      bid_idpk: outbox.idpk,
      bid_msg_id: message_id,
      side: "buy",
      buyer_city: ENV.fetch("CITY_ID", "TK3"),
      seller_city: candidate[:city_id],
      quantity: candidate[:quantity],
      price_per_energy: candidate[:price_per_energy],
      amount: (candidate[:quantity] * candidate[:price_per_energy]).round(2),
      status: "sent",
      raw_payload: candidate[:payload]
    )
  end

  def remaining_deficit(cycle)
    deficit = [cycle.consumption.to_d - cycle.generation_capacity.to_d, 0].max.ceil
    purchased = MarketBid.where(cycle_id: cycle.cycle_id, side: "buy", status: "settled").sum(:quantity)
    pending = MarketBid.unresolved_buy(cycle.cycle_id).sum(:quantity)
    [deficit - purchased - pending, 0].max
  end

  def timeout_unanswered_bids(cycle, now)
    MarketBid.where(cycle_id: cycle.cycle_id, side: "buy", status: "sent")
             .where("created_at <= ?", now - 60.seconds)
             .update_all(status: "timed_out", updated_at: now)
  end

  def settled_sales(cycle)
    MarketBid.where(cycle_id: cycle.cycle_id, side: "sell", status: "settled").sum(:quantity)
  end

  def available_wallet_kwh
    balance = WalletClient.new.get_balance
    available = balance&.dig("assets", "KWH", "available")
    raise WalletClient::RetryableFailure, "GET /balance no entregó assets.KWH.available" if available.nil?

    available.to_i
  end

  def offer_attributes(offer)
    {
      cityId: offer.city_id,
      offerId: offer.offer_id,
      remaining: offer.remaining - offer.reserved_quantity,
      pricePerEnergy: offer.price_per_energy
    }
  end

  def schedule_at(cycle, time)
    self.class.set(wait_until: time).perform_later(cycle.cycle_id) if time && time > Time.current
  end
end
