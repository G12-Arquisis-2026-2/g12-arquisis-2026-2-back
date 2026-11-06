# Saldos que se reportan en el negotiation-report de un ciclo (§ Sobre el presupuesto).
#
# budget: acumulado entre ciclos ("el budget se traspasa entre ciclos"). Es la suma del ledger y de
#   swaps liquidados hasta el cierre del ciclo. El cobro de un give llega como transfer, no se suma
#   dos veces. Lo de ciclos posteriores no entra: el orden lo da el validUntil del status-statement.
# energy: solo del ciclo (la energía no se almacena): generationCapacity - consumption del
#   status-statement, los movimientos del ledger y swaps liquidados (buy +quantity, sell -quantity).
#   Un give cuenta solo si llegó su pago: sin transfer "no hubo operación real" (§ Pago).
class CycleBalanceService
  def self.call(cycle)
    { budget: budget(cycle), energy: energy(cycle) }
  end

  def self.budget(cycle)
    later = Cycle.where("(COALESCE(valid_until, created_at), id) > (?, ?)",
                        cycle.valid_until || cycle.created_at, cycle.id)
    ledger_budget = Transaction.where.not(cycle_id: later.select(:cycle_id)).sum(:budget_change)
    swap_budget = MarketBid.where(status: "settled")
                           .where.not(cycle_id: later.select(:cycle_id))
                           .sum("CASE WHEN side = 'sell' THEN amount ELSE -amount END")
    ledger_budget + swap_budget
  end

  def self.energy(cycle)
    own = cycle.generation_capacity.to_d - cycle.consumption.to_d
    moves = Transaction.where(cycle_id: cycle.cycle_id).where.not(<<~SQL.squish).sum(:energy_change)
      operation_type = 'give' AND NOT EXISTS (
        SELECT 1 FROM transactions payment
        WHERE payment.operation_type = 'transfer'
          AND payment.raw_data -> 'data' ->> 'becauseOf' = transactions.raw_data ->> 'msgId'
      )
    SQL
    swaps = MarketBid.where(cycle_id: cycle.cycle_id, status: "settled")
                     .sum("CASE WHEN side = 'buy' THEN quantity ELSE -quantity END")
    own + moves + swaps
  end

  private_class_method :budget, :energy
end
