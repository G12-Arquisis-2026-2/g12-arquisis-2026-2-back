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
      fundsReceived: funds_received,
      demandStatements: demand_statements,
      voluntaryNegotiations: voluntary_negotiations,
      negotiationReport: negotiation_report_data,
      finalBalances: final_balances,
      lastOperation: last_operation
    }
  end

  private

  # 1. Status Statement
  def status_statement_data
    # Buscar en la bitácora o eventos la recepción del status-statement
    audit = AuditLog.where(event_type: "status-statement")
                    .where("raw_payload ->> 'cycleId' = ?", @cycle_id)
                    .order(created_at: :desc).first
    return nil unless audit

    data = audit.raw_payload["data"] || {}
    energy = data["energy"] || {}

    {
      energy: {
        generationCapacity: energy["generationCapacity"]&.to_i || 0,
        consumption: energy["consumption"]&.to_i || 0,
        generationCost: energy["generationCost"]&.to_f || 0.0
      },
      validUntil: data["validUntil"] || @cycle.valid_until&.iso8601
    }
  end

  # 2. Transferencias de fondos recibidas
  def funds_received
    AuditLog.where(event_type: "transfer")
            .where("raw_payload ->> 'cycleId' = ?", @cycle_id)
            .sum("CAST(raw_payload -> 'data' ->> 'quantity' AS NUMERIC)")
            .to_f
  end

  # 3. Demand statements aplicados en el ledger
  def demand_statements
    AuditLog.where(event_type: "demand-statement")
            .where("raw_payload ->> 'cycleId' = ?", @cycle_id)
            .order(created_at: :asc)
            .map do |log|
              data = log.raw_payload["data"] || {}
              balance = data["balance"] || {}
              {
                quantity: balance["quantity"]&.to_i || 0,
                valuePerKwh: balance["valuePerKwh"]&.to_f || 0.0,
                appliedAt: log.created_at.iso8601
              }
            end
  end

  # 4. Propuestas voluntarias realizadas
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

  # 5. Reporte de cierre (negotiation-report)
  def negotiation_report_data
    return nil unless @cycle.report_sent?

    {
      budgetBalance: @cycle.reported_budget,
      energyBalance: @cycle.reported_energy,
      sentAt: @cycle.updated_at.iso8601
    }
  end

  # 6. Balances finales del ciclo
  def final_balances
    balances = CycleBalanceService.call(@cycle)
    {
      budget: balances[:budget],
      energy: balances[:energy]
    }
  end

  # 7. Identificar la última operación aplicada en el ciclo (RF01)
  def last_operation
    operations = []

    if @cycle.report_sent?
      operations << { type: "negotiation-report", time: @cycle.updated_at }
    end

    last_audit = AuditLog.where("raw_payload ->> 'cycleId' = ?", @cycle_id)
                         .order(created_at: :desc).first
    if last_audit
      operations << { type: last_audit.event_type, time: last_audit.created_at }
    end

    last_prop = Proposal.where(cycle_id: @cycle_id).order(updated_at: :desc).first
    if last_prop
      operations << { type: "negotiation-proposal", time: last_prop.updated_at }
    end

    latest = operations.max_by { |op| op[:time] }
    latest ? latest[:type] : "none"
  end
end