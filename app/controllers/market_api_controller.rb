class MarketApiController < ApplicationController
  def live
    cycle = current_cycle

    if cycle.nil?
      render json: { cycle: nil, offers: [], bids: [] }, status: :ok
      return
    end

    render json: {
      cycleId: cycle.cycle_id,
      offers: MarketOffer.where(cycle_id: cycle.cycle_id).order(created_at: :desc).as_json,
      bids: MarketBid.where(cycle_id: cycle.cycle_id).order(created_at: :desc).as_json
    }, status: :ok
  end

  def span
    cycles = Cycle.where.not(valid_until: nil).order(valid_until: :desc)
    experiments = cycles.map do |cycle|
      settled_buys = MarketBid.where(cycle_id: cycle.cycle_id, side: "buy", status: "settled")
      purchased_kwh = settled_buys.sum(:quantity).to_i
      purchased_cr = settled_buys.sum(:amount).to_d

      {
        cycleId: cycle.cycle_id,
        span: cycle.market_strategy&.span_seconds,
        deficitCovered: purchased_kwh,
        effectiveCost: purchased_kwh.zero? ? 0.0 : (purchased_cr / purchased_kwh).to_f,
        baseline: cycle.imbalance_price&.to_f,
        rejectedBids: MarketBid.where(cycle_id: cycle.cycle_id, status: %w[rejected timed_out]).count
      }
    end

    render json: experiments, status: :ok
  end

  private

  def current_cycle
    Cycle.where.not(valid_until: nil).order(valid_until: :desc).first
  end
end
