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

    energy_change, budget_change = case type
    when "transfer"
      quantity = decimal(data.fetch("quantity"))
      [0, quantity]
    when "demand-statement"
      balance = data["balance"]
      quantity_value = data["quantity"] || (balance.is_a?(Hash) ? balance["quantity"] : balance)
      value_per_kwh_value = data["valuePerKwh"] || (balance["valuePerKwh"] if balance.is_a?(Hash))
      quantity = decimal(quantity_value)
      value_per_kwh = decimal(value_per_kwh_value)
      [quantity, -quantity * value_per_kwh]
    when "give"
      # Entregamos energía. El cobro NO va aquí: la central lo paga con un transfer
      # (data.becauseOf = msgId de este give), que ya suma al budget.
      [-decimal(data.fetch("energy")), 0]
    when "take"
      # Recibimos energía y pagamos nosotros (§ Pago): ningún transfer entrante lo refleja.
      # pricePerEnergy ya viene redondeado por la central; el total se redondea a 2 decimales.
      energy = decimal(data.fetch("energy"))
      [energy, -(energy * decimal(data.fetch("pricePerEnergy"))).round(2)]
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