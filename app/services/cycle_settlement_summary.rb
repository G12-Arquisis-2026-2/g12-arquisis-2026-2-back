# RF01: transportCharges e imbalanceSettlement del resumen de ciclo, con la forma de TransportCharge e
# ImbalanceSettlement en front/frontend/src/types/api.ts. Los montos van como número (to_f), no string.
class CycleSettlementSummary
  # cycle: un Cycle (lo que recibe CyclePresenter) o directamente su cycle_id.
  def self.call(cycle)
    new(cycle).as_json
  end

  def initialize(cycle)
    @cycle_id = cycle.respond_to?(:cycle_id) ? cycle.cycle_id : cycle.to_s
    @city_id = ENV.fetch("CITY_ID", "TK3")
  end

  def as_json
    { transportCharges: transport_charges, imbalanceSettlement: imbalance_settlement }
  end

  private

  # Solo donde somos el comprador: la central cobra el transporte al comprador, nunca al vendedor.
  def transport_charges
    trades = TradeRecord.where(cycle_id: @cycle_id, buyer: @city_id).order(:recorded_at, :id).to_a
    routes = DistanceTable.where(destination_code: trades.map(&:seller)).index_by(&:destination_code)

    trades.map { |trade| transport_charge(trade, routes[trade.seller]) }
  end

  # distanceKm y unitCost salen de nuestra distance-table: trade-recorded solo trae transportPerEnergy,
  # que la central calcula como round2(km × transportCost).
  def transport_charge(trade, route)
    {
      counterpartCityId: trade.seller,
      distanceKm: route && (route.distance.to_d / 1000).to_f,
      unitCost: route && unit_cost(route, trade.route_enabled)&.to_f,
      totalCost: trade.transport_total.to_f,
      routeDisabledPenalty: !trade.route_enabled,
      appliedAt: trade.recorded_at&.iso8601
    }
  end

  def unit_cost(route, enabled)
    enabled ? route.transport_cost : route.disabled_route_transport_cost
  end

  # coverage y totalAmount con el signo de la central; type lo deja explícito para la vista.
  def imbalance_settlement
    settlement = ImbalanceSettlement.where(cycle_id: @cycle_id).order(:settled_at, :id).last
    return nil unless settlement

    {
      coverageKwh: settlement.coverage,
      pricePerKwh: settlement.price_per_energy.to_f,
      totalAmount: settlement.total.to_f,
      type: settlement.coverage.negative? ? "deficit" : "surplus",
      settledAt: settlement.settled_at&.iso8601
    }
  end
end
