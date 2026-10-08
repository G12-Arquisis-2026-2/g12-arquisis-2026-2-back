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
      reportTracking: report_tracking,
      finalBalances: final_balances,
      lastOperation: last_operation
    }
  end

  private

  # 1. Obtenido directamente del modelo Cycle
  def status_statement_data
    return nil unless @cycle.valid_until.present?

    {
      energy: {
        generationCapacity: @cycle.generation_capacity || 0,
        consumption: @cycle.consumption || 0,
        generationCost: @cycle.generation_cost || 0.0
      },
      validUntil: @cycle.valid_until.iso8601
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
      budgetBalance: @cycle.reported_budget,
      energyBalance: @cycle.reported_energy,
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
      budget: balances[:budget],
      energy: balances[:energy]
    }
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