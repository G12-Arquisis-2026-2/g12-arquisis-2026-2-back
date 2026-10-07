# Saldos que se reportan en el negotiation-report de un ciclo (§ Sobre el presupuesto).
#
# budget: acumulado entre ciclos ("el budget se traspasa entre ciclos"). Es la suma de todo el ledger:
#   transfer (+quantity, la multa ya viene descontada ahí), demand-statement (-q * valuePerKwh) y
#   take (-energy * pricePerEnergy). El cobro de un give llega como transfer, no se suma dos veces.
# energy: solo del ciclo (la energía no se almacena): generationCapacity - consumption del
#   status-statement, más demand-statement (+q), take (+energy) y give (-energy). Un give cuenta solo
#   si llegó su pago: sin transfer "no hubo operación real" (§ Pago).
class CycleBalanceService
  def self.call(cycle)
    { budget: budget, energy: energy(cycle) }
  end

  def self.budget
    Transaction.sum(:budget_change)
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
    own + moves
  end

  private_class_method :budget, :energy
end
