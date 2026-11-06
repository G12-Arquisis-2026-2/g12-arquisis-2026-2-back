class MarketStrategiesController < ApplicationController
  def show
    render json: strategy_json(MarketStrategy.current)
  end

  def update
    current = MarketStrategy.current
    attributes = current.attributes.slice(
      "sell_price_multiplier",
      "max_buy_effective_price_ratio",
      "span_seconds"
    ).merge(strategy_params)
    strategy = MarketStrategy.activate!(attributes)
    render json: strategy_json(strategy), status: :created
  rescue ActiveRecord::RecordInvalid => error
    render json: { errors: error.record.errors.to_hash }, status: :unprocessable_entity
  end

  private

  def strategy_params
    attributes = params[:marketStrategy] || params[:market_strategy]
    raise ActionController::ParameterMissing, :marketStrategy unless attributes

    attributes.permit(:sellPriceMultiplier, :maxBuyEffectivePriceRatio, :spanSeconds)
              .to_h
              .transform_keys(&:underscore)
  end

  def strategy_json(strategy)
    {
      id: strategy.id,
      sellPriceMultiplier: strategy.sell_price_multiplier,
      maxBuyEffectivePriceRatio: strategy.max_buy_effective_price_ratio,
      spanSeconds: strategy.span_seconds,
      createdAt: strategy.created_at
    }
  end
end
