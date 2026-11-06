class StatusStatementProcessorService
  def self.call(payload)
    data = payload.fetch("data")
    energy = data.fetch("energy")
    market = data["market"].is_a?(Hash) ? data["market"] : {}

    ProcessedMessage.process_once(payload) do
      cycle = Cycle.find_or_initialize_by(cycle_id: payload.fetch("cycleId"))
      cycle.assign_attributes(
        generation_capacity: energy.fetch("generationCapacity"),
        consumption: energy.fetch("consumption"),
        generation_cost: energy.fetch("generationCost"),
        valid_until: data.fetch("validUntil"),
        sellable: energy["sellable"],
        buyback_price: market["buybackPrice"],
        imbalance_price: market["imbalancePrice"],
        min_bid: market["minBid"],
        market_opens_at: market["opensAt"],
        last_offer_at: market["lastOfferAt"],
        last_bid_at: market["lastBidAt"],
        closes_at: market["closesAt"],
        report_opens_at: market["reportOpensAt"]
      )
      cycle.save!
      if data["market"].is_a?(Hash)
        NegotiationStrategyService.for_cycle(cycle)
        MarketCycleJob.perform_later(cycle.cycle_id)
      end
    end
  end
end
