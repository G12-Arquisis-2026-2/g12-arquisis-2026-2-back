class CyclePresenter
  def self.format(cycle)
    new(cycle).as_json
  end

  def initialize(cycle)
    @cycle = cycle
    @cycle_id = cycle.cycle_id
  end

  def as_json
    {
      cycleId: @cycle_id,
      statusStatement: status_statement_data,
      marketStrategy: market_strategy_data,
      fundsReceived: funds_received,
      negotiationReport: negotiation_report_data,
      reportTracking: report_tracking,
      finalBalances: final_balances,
      lastOperation: last_operation,
      ownOffer: own_offer,
      bidsSent: bids_sent,
      bidsReceived: bids_received,
      swaps: swaps,
      transportCharges: transport_charges,
      imbalanceSettlement: imbalance_settlement
    }
  end

  private

  # 1. Obtenido directamente del modelo Cycle
  def status_statement_data
    return nil unless @cycle.valid_until.present?

    statement = {
      energy: {
        generationCapacity: numeric(@cycle.generation_capacity),
        consumption: numeric(@cycle.consumption),
        generationCost: numeric(@cycle.generation_cost)
      },
      validUntil: @cycle.valid_until.iso8601
    }
    statement[:energy][:sellable] = @cycle.sellable if @cycle.sellable
    statement[:market] = market_data if market_data
    statement
  end

  def market_data
    return nil if @cycle.buyback_price.blank? && @cycle.imbalance_price.blank?

    {
      buybackPrice: numeric(@cycle.buyback_price),
      imbalancePrice: numeric(@cycle.imbalance_price),
      minBid: @cycle.min_bid,
      opensAt: @cycle.market_opens_at&.iso8601,
      lastOfferAt: @cycle.last_offer_at&.iso8601,
      lastBidAt: @cycle.last_bid_at&.iso8601,
      closesAt: @cycle.closes_at&.iso8601,
      reportOpensAt: @cycle.report_opens_at&.iso8601
    }
  end

  def market_strategy_data
    strategy = @cycle.market_strategy
    return nil unless strategy

    {
      id: strategy.id,
      sellPriceMultiplier: numeric(strategy.sell_price_multiplier),
      maxBuyEffectivePriceRatio: numeric(strategy.max_buy_effective_price_ratio),
      spanSeconds: strategy.span_seconds.to_i
    }
  end

  # 2. Transferencias de fondos acreditadas en la tabla de transacciones.
  # Un transfer con becauseOf es el pago de un give, no fondos de la central: no se suma aquí.
  def funds_received
    Transaction.where(cycle_id: @cycle_id, operation_type: 'transfer')
               .where("COALESCE(raw_data -> 'data' ->> 'becauseOf', '') = ''")
               .sum(:budget_change)
               .to_f
  end

  # 3. Demand statements registrados en la tabla de transacciones
  def demand_statements
    Transaction.where(cycle_id: @cycle_id, operation_type: 'demand-statement')
               .order(created_at: :asc)
               .map do |tx|
                 raw = tx.raw_data || {}
                 balance = raw.dig('data', 'balance') || {}
                 {
                   quantity: balance['quantity']&.to_i || tx.energy_change.abs,
                   valuePerKwh: balance['valuePerKwh']&.to_f || 0.0,
                   appliedAt: tx.created_at.iso8601
                 }
               end
  end

  # 4. Propuestas de negociación en la tabla proposals
  def voluntary_negotiations
    Proposal.where(cycle_id: @cycle_id).order(created_at: :asc).map do |prop|
      {
        proposalId: prop.idpk,
        direction: prop.direction,
        quantity: prop.quantity,
        pricePerEnergy: prop.price_per_energy,
        status: prop.status
      }
    end
  end

  # 5. Estado del reporte de negociación en el modelo Cycle
  def negotiation_report_data
    return nil unless @cycle.report_sent?

    {
      budgetBalance: numeric(@cycle.reported_budget),
      energyBalance: numeric(@cycle.reported_energy),
      sentAt: report_sent_at&.iso8601
    }
  end

  # Hora en que el connector publicó el último reporte encolado (report_msg_id), no cualquier otro
  # reporte del ciclo. Sin valor mientras está pendiente o si quedó fallido.
  def report_sent_at
    return @report_sent_at if defined?(@report_sent_at)

    @report_sent_at = OutboxMessage.find_by(msg_id: @cycle.report_msg_id, status: "sent")&.sent_at
  end

  # Seguimiento del reporte: si la ventana cerró sin reporte entregado (missedAt) y si la central
  # lo rechazó con REPORT_TOO_EARLY y falta reenviarlo (se reintenta desde notBefore).
  def report_tracking
    {
      missedAt: @cycle.report_missed_at&.iso8601,
      tooEarly: @cycle.report_not_before.present?,
      notBefore: @cycle.report_not_before&.iso8601
    }
  end

  # 6. Saldos consolidados desde CycleBalanceService
  def final_balances
    balances = CycleBalanceService.call(@cycle)
    {
      budget: numeric(balances[:budget]),
      energy: numeric(balances[:energy])
    }
  end

  def own_offer
    offer = MarketOffer.find_by(cycle_id: @cycle_id, city_id: ENV.fetch("CITY_ID", "TK3"))
    return nil unless offer

    {
      id: offer.id,
      offerId: offer.offer_id,
      quantity: offer.quantity.to_i,
      remaining: offer.remaining.to_i,
      reservedQuantity: offer.reserved_quantity.to_i,
      pricePerEnergy: numeric(offer.price_per_energy),
      active: offer.active
    }
  end

  def bids_sent
    MarketBid.where(cycle_id: @cycle_id, side: "buy").order(created_at: :desc).map { |bid| bid_json(bid) }
  end

  def bids_received
    MarketBid.where(cycle_id: @cycle_id, side: "sell").order(created_at: :desc).map { |bid| bid_json(bid) }
  end

  def bid_json(bid)
    {
      id: bid.id,
      bidIdpk: bid.bid_idpk,
      offerId: bid.offer_id,
      sellerCity: bid.seller_city,
      buyerCity: bid.buyer_city,
      quantity: bid.quantity.to_i,
      pricePerEnergy: numeric(bid.price_per_energy),
      amount: numeric(bid.amount),
      status: bid.status,
      swapId: bid.swap_id,
      expiresAt: bid.expires_at&.iso8601,
      createdAt: bid.created_at.iso8601
    }
  end

  def swaps
    SwapIntention.where(cycle_id: @cycle_id).order(created_at: :desc).map do |swap|
      {
        id: swap.id,
        idpk: swap.idpk,
        swapId: swap.swap_id,
        status: swap.status,
        giveAmount: numeric(swap.give_amount),
        takeAmount: numeric(swap.take_amount),
        expiresAt: swap.expires_at&.iso8601,
        createdAt: swap.created_at.iso8601
      }
    end
  end

  def transport_charges
    MarketBid.where(cycle_id: @cycle_id, side: "buy", status: "settled").sum do |bid|
      route = DistanceTable.find_by(destination_code: bid.seller_city)
      bid.quantity.to_d * (route&.transport_cost || 0).to_d
    end.to_f
  end

  def imbalance_settlement
    audit = AuditLog.where(event_type: "IMBALANCE_SETTLEMENT")
                    .where("raw_payload ->> 'cycleId' = ?", @cycle_id)
                    .order(created_at: :desc)
                    .first
    return nil unless audit&.raw_payload.is_a?(Hash)

    data = audit.raw_payload.fetch("data", {})
    {
      kwhHeld: numeric(data["kwhHeld"]),
      deficit: numeric(data["deficit"]),
      coverage: numeric(data["coverage"]),
      pricePerEnergy: numeric(data["pricePerEnergy"]),
      total: numeric(data["total"]),
      balanceAfter: numeric(data["balanceAfter"]),
      settlementId: data["settlementId"],
      recordedAt: audit.created_at.iso8601
    }
  end

  def numeric(value)
    value.present? ? value.to_f : 0.0
  end

  # 7. Identifica el tipo de la última operación de dominio efectuada en el ciclo
  def last_operation
    operations = []

    if @cycle.report_sent? && report_sent_at
      operations << { type: "negotiation-report", time: report_sent_at }
    end

    last_tx = Transaction.where(cycle_id: @cycle_id).order(created_at: :desc).first
    if last_tx
      operations << { type: last_tx.operation_type, time: last_tx.created_at }
    end

    last_prop = Proposal.where(cycle_id: @cycle_id).order(updated_at: :desc).first
    if last_prop
      operations << { type: "negotiation-proposal", time: last_prop.updated_at }
    end

    if @cycle.valid_until.present?
      operations << { type: "status-statement", time: @cycle.created_at }
    end

    latest = operations.max_by { |op| op[:time] }
    latest ? latest[:type] : "none"
  end
end