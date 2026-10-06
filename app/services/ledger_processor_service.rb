class LedgerProcessorService
  def self.call(payload)
    new(payload).call
  end

  def initialize(payload)
    @payload = payload
  end

  def call
    type = @payload.fetch("type")
    data = @payload.fetch("data")
    quantity = decimal(data.fetch("quantity"))

    energy_change, budget_change = case type
    when "transfer"
      [0, quantity]
    when "demand-statement"
      value_per_kwh = decimal(data.fetch("valuePerKwh"))
      [quantity, -quantity * value_per_kwh]
    else
      raise ArgumentError, "Unsupported ledger operation type: #{type.inspect}"
    end

    begin
      Transaction.transaction(requires_new: true) do
        Transaction.create!(
          idpk: @payload.fetch("idpk"),
          cycle_id: @payload.fetch("cycleId"),
          operation_type: type,
          energy_change: energy_change,
          budget_change: budget_change,
          raw_data: @payload
        )
      end
    rescue ActiveRecord::RecordNotUnique
      log_duplicate
    rescue ActiveRecord::RecordInvalid => error
      raise unless error.record.errors.of_kind?(:idpk, :taken)

      log_duplicate
    end
  end

  private

  def decimal(value)
    BigDecimal(value.to_s)
  end

  def log_duplicate
    AuditLog.create!(
      idpk: @payload.fetch("idpk"),
      event_type: "DUPLICATE",
      reason: "Message rejected due to retry",
      raw_payload: @payload
    )

    false
  end
end