class MarketApiController < ApplicationController
  def live
    cycle = current_cycle
    offers = if cycle
      routes = DistanceTable.all.index_by(&:destination_code)
      MarketOffer.where(cycle_id: cycle.cycle_id).order(created_at: :desc).map do |offer|
        route = routes[offer.city_id]
        pricing = route && NegotiationStrategyService.route_pricing(
          route: route, city_id: offer.city_id, price_per_energy: offer.price_per_energy
        )
        {
          offerId: offer.offer_id,
          cityId: offer.city_id,
          quantity: offer.quantity,
          remaining: offer.remaining,
          reservedQuantity: offer.reserved_quantity,
          pricePerEnergy: offer.price_per_energy&.to_f,
          active: offer.active,
          distanceKm: pricing&.dig(:distance_km)&.to_f,
          transportCostPerKwh: pricing&.dig(:transport_cost_per_kwh)&.to_f,
          effectivePrice: pricing&.dig(:effective_price)&.to_f,
          routeEnabled: pricing&.dig(:route_enabled)
        }
      end
    else
      []
    end

    render json: {
      cityId: ENV.fetch("CITY_ID", "TK3"),
      updatedAt: cycle && MarketOffer.where(cycle_id: cycle.cycle_id).maximum(:updated_at)&.iso8601,
      offers: offers
    }, status: :ok
  end

  def swaps
    cycle = current_cycle
    swaps = if cycle
      MarketBid.where(cycle_id: cycle.cycle_id).order(created_at: :desc).map do |bid|
        {
          cycleId: bid.cycle_id,
          offerId: bid.offer_id,
          bidIdpk: bid.bid_idpk,
          bidMsgId: bid.bid_msg_id,
          side: bid.side,
          buyerCity: bid.buyer_city,
          sellerCity: bid.seller_city,
          quantity: bid.quantity,
          pricePerEnergy: bid.price_per_energy&.to_f,
          amount: bid.amount&.to_f,
          status: bid.status,
          proposalIdpk: bid.proposal_idpk,
          acceptIdpk: bid.accept_idpk,
          swapId: bid.swap_id,
          expiresAt: bid.expires_at&.iso8601,
          createdAt: bid.created_at.iso8601,
          updatedAt: bid.updated_at.iso8601
        }
      end
    else
      []
    end
    render json: {
      cityId: ENV.fetch("CITY_ID", "TK3"),
      cycleId: cycle&.cycle_id,
      updatedAt: cycle && MarketBid.where(cycle_id: cycle.cycle_id).maximum(:updated_at)&.iso8601,
      swaps: swaps
    }, status: :ok
  end

    def span
    routes = DistanceTable.all.index_by(&:destination_code)
    cycles = Cycle.where.not(valid_until: nil).order(valid_until: :desc).limit(300)
    experiments = cycles.map do |cycle|
      settled_buys = MarketBid.where(cycle_id: cycle.cycle_id, side: "buy", status: "settled").to_a
      purchased_kwh = settled_buys.sum { |b| b.quantity.to_d }
      purchased_cr  = settled_buys.sum { |b| b.amount.to_d }
      transport = settled_buys.sum do |b|
        route = routes[b.seller_city]
        route ? b.quantity.to_d * route.distance.to_d / 1000 * route.transport_cost.to_d : 0
      end
      imbalance = cycle.imbalance_price.to_d
      deficit   = [cycle.consumption.to_d - cycle.generation_capacity.to_d, 0].max
      uncovered = [deficit - purchased_kwh, 0].max
      baseline  = deficit * imbalance
      paid      = purchased_cr + transport + uncovered * imbalance  
      rejected  = MarketBid.where(cycle_id: cycle.cycle_id, status: %w[rejected timed_out]).count
      {
        cycleId: cycle.cycle_id,
        configuredSpanSeconds: cycle.market_strategy&.span_seconds,
        initialDeficitKwh: deficit.to_f,
        coveredDeficitKwh: purchased_kwh.to_f,
        effectiveCostPaid: paid.to_f,
        baselineCost: baseline.to_f,
        bidsRejectedCount: rejected,
        completedAt: cycle.valid_until&.iso8601
      }
    end
    render json: experiments, status: :ok
  end

  private

  def current_cycle
    Cycle.where.not(valid_until: nil).order(valid_until: :desc).first
  end
end
