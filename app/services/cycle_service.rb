class CycleService
  # Solicitud directa de estado si status-statement no ha llegado en la ventana de negociación
  def self.build_direct_request(city_id)
    {
      idpk: SecureRandom.uuid,
      type: "request",
      cityId: city_id,
      timestamp: Time.current.iso8601
    }
  end

  # Construcción del reporte final de balance energético y presupuesto del ciclo
  def self.build_negotiation_report(cycle_id:, budget_balance:, energy_balance:)
    {
      idpk: SecureRandom.uuid,
      type: "negotiation-report",
      cycleId: cycle_id,
      data: {
        budgetBalance: budget_balance,
        energyBalance: energy_balance
      },
      timestamp: Time.current.iso8601
    }
  end
end