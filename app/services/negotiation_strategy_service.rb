class NegotiationStrategyService
  def self.for_cycle(cycle)
    cycle.with_lock do
      cycle.market_strategy ||= MarketStrategy.current
      cycle.save! if cycle.changed?
      cycle.market_strategy
    end
  end

  def self.build_offer(cycle:, offer_id:, quantity:, strategy: for_cycle(cycle), now: Time.current)
    return if cycle.last_offer_at && now >= cycle.last_offer_at
    quantity = quantity.to_d.floor
    return if quantity <= 0 || cycle.buyback_price.blank? || cycle.imbalance_price.blank?

    floor = cycle.buyback_price.to_d
    ceiling = cycle.imbalance_price.to_d
    return if floor > ceiling

    price = [[floor * strategy.sell_price_multiplier.to_d, floor].max, ceiling].min.round(2)
    {
      type: "offer",
      cycleId: cycle.cycle_id,
      data: { offerId: offer_id, quantity: quantity, pricePerEnergy: price }
    }
  end

  def self.best_buy_bid(cycle:, offers:, distances:, energy_needed:, strategy: for_cycle(cycle), now: Time.current)
    needed = energy_needed.to_d.floor
    return if needed <= 0
    return if cycle.last_bid_at && now >= cycle.last_bid_at
    return if cycle.min_bid.nil? || cycle.imbalance_price.nil?

    minimum_bid = cycle.min_bid.to_d
    price_limit = cycle.imbalance_price.to_d * strategy.max_buy_effective_price_ratio.to_d

    offers.filter_map do |offer|
      city_id = fetch(offer, :cityId)
      available = fetch(offer, :remaining) || fetch(offer, :quantity)
      offer_id = fetch(offer, :offerId)
      offer_price = fetch(offer, :pricePerEnergy)
      next if city_id.blank? || offer_id.blank? || available.nil? || offer_price.nil?

      available = available.to_d.floor
      quantity = [needed, available].min
      next if city_id == ENV.fetch("CITY_ID", "TK3") || quantity < minimum_bid

      route = distance_for(distances, city_id)
      next unless route

      pricing = route_pricing(route: route, city_id: city_id, price_per_energy: offer_price)
      next unless pricing && pricing[:effective_price]

      effective_price = pricing[:effective_price]
      next if effective_price > price_limit

      {
        city_id: city_id,
        offer_id: offer_id,
        quantity: quantity,
        price_per_energy: offer_price.to_d,
        effective_price_per_energy: effective_price,
        payload: {
          type: "bid",
          cycleId: cycle.cycle_id,
          data: { offerId: offer_id, quantity: quantity }
        }
      }
    end.min_by { |candidate| [candidate[:effective_price_per_energy], -candidate[:quantity]] }
  end

  def self.route_pricing(route:, city_id:, price_per_energy:)
    route_enabled = route_value(route, :enabled) == true
    distance_km = route_value(route, :distance).to_d / 1000
    transport_cost_key = route_enabled ? :transportCost : :disabledRouteTransportCost
    transport_cost = begin
      route_value(route, transport_cost_key).to_d
    rescue KeyError
      Rails.logger.warn("[NegotiationStrategyService] Omitiendo ruta #{city_id}: falta #{transport_cost_key}")
      return {
        distance_km: distance_km,
        transport_cost_per_kwh: nil,
        effective_price: nil,
        route_enabled: route_enabled
      }
    end

    {
      distance_km: distance_km,
      transport_cost_per_kwh: transport_cost,
      effective_price: (price_per_energy.to_d + (distance_km * transport_cost).round(2)).round(2),
      route_enabled: route_enabled
    }
  rescue KeyError
    Rails.logger.warn("[NegotiationStrategyService] Omitiendo ruta #{city_id}: falta un campo de ruta")
    nil
  end

  def self.bid_rejection_reason(cycle:, offer_id:, bid:, remaining:, now: Time.current)
    data = bid.fetch("data")
    return "MARKET_CLOSED" if cycle.market_closed_at
    return "MARKET_CLOSED" if cycle.closes_at.nil? || now >= cycle.closes_at
    return "MARKET_CLOSED" if cycle.last_bid_at && now >= cycle.last_bid_at
    return "OFFER_WITHDRAWN" unless data["offerId"] == offer_id
    return "SELF_TRADE" if bid["cityId"] == ENV.fetch("CITY_ID", "TK3")
    return "BID_TOO_SMALL" if data.fetch("quantity").to_d < cycle.min_bid.to_d
    return "QUANTITY_UNAVAILABLE" if data.fetch("quantity").to_d > remaining.to_d

    nil
  end

  def self.distance_for(distances, city_id)
    if distances.respond_to?(:find_by)
      distances.find_by(destination_code: city_id)
    else
      distances[city_id] || distances[city_id.to_sym]
    end
  end

  def self.route_enabled?(route)
    route_value(route, :enabled) == true
  end

  def self.route_value(route, key)
    value = if route.respond_to?(:attributes)
      route.public_send(key.to_s.underscore)
    elsif route.key?(key.to_s)
      route[key.to_s]
    else
      route[key.to_sym]
    end
    raise KeyError, "missing route field #{key}" if value.nil?

    value
  end

  def self.fetch(hash, key)
    hash[key.to_s] || hash[key.to_sym]
  end

  private_class_method :distance_for, :route_enabled?, :route_value, :fetch
end
