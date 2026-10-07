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
      # Entregamos energía. El cobro no va aquí: la central lo paga con un transfer
      # (data.becauseOf = msgId de este give), que ya suma al budget.
      [-decimal(data.fetch("energy")), 0]
    when "take"
      # Recibimos energía y pagamos nosotros (§ Pago): emitiremos el transfer correspondiente.
      energy = decimal(data.fetch("energy"))
      [energy, -(energy * decimal(data.fetch("pricePerEnergy"))).round(2)]
    else
      raise ArgumentError, "Unsupported ledger operation type: #{type.inspect}"
    end

    begin
      Transaction.transaction(requires_new: true) do
        # 1. Registrar la transacción en el ledger local
        Transaction.create!(
          idpk: @payload.fetch("idpk"),
          cycle_id: @payload.fetch("cycleId"),
          operation_type: type,
          energy_change: energy_change,
          budget_change: budget_change,
          raw_data: @payload
        )

        # 2. Manejo de estados de la propuesta y emisión de pagos
        case type
        when "give"
          handle_give_confirmation(data["target"], @payload.fetch("cycleId"))

        when "take"
          handle_take_confirmation_and_payment(data, @payload.fetch("cycleId"), @payload.fetch("msgId"))

        when "transfer"
          if data["becauseOf"].present?
            handle_transfer_payment(data["becauseOf"], @payload.fetch("cycleId"))
          end
        end
      end
    rescue ActiveRecord::RecordNotUnique
      log_duplicate
    rescue ActiveRecord::RecordInvalid => error
      raise unless error.record.errors.of_kind?(:idpk, :taken)

      log_duplicate
    end
  end

  private

  # Cuando llega la confirmación 'give' de la central: pasa la propuesta a CONFIRMED
  def handle_give_confirmation(target_msg_id, cycle_id)
    proposal = find_proposal_by_target_or_cycle(target_msg_id, cycle_id, direction: "give")
    proposal&.update!(status: "CONFIRMED")
  end

  # Cuando llega el mensaje 'take' de la central:
  # 1. Cambia la propuesta a PAID
  # 2. Emite la transferencia (transfer) hacia la central con becauseOf = msgId del take
  def handle_take_confirmation_and_payment(data, cycle_id, take_msg_id)
    proposal = find_proposal_by_target_or_cycle(data["target"], cycle_id, direction: "take")
    proposal&.update!(status: "PAID")

    # Emisión de la transferencia de pago a la central
    energy = decimal(data.fetch("energy"))
    price_per_energy = decimal(data.fetch("pricePerEnergy"))
    quantity = (energy * price_per_energy).round(2)

    transfer_payload = {
      type: "transfer",
      cycleId: cycle_id,
      data: {
        becauseOf: take_msg_id, # Referencia obligatoria al msgId del mensaje take
        quantity: quantity
      }
    }

    RabbitMQPublisher.publish(transfer_payload) if defined?(RabbitMQPublisher)
  end

  # Cuando llega un 'transfer' entrante de la central con becauseOf (pago de una venta give):
  # Encuentra la propuesta give correspondiente y la marca como PAID
  def handle_transfer_payment(because_of_msg_id, cycle_id)
    # 1. Intentar encontrar la transacción de confirmación 'give' que generó este pago
    give_tx = Transaction.find_by("operation_type = 'give' AND raw_data->>'msgId' = ?", because_of_msg_id)
    target_msg_id = give_tx&.raw_data&.dig("data", "target")

    # 2. Buscar la propuesta asociada y marcarla como PAID
    proposal = find_proposal_by_target_or_cycle(target_msg_id, cycle_id, direction: "give")
    proposal&.update!(status: "PAID")
  end

  # Busca la propuesta primero mediante el árbol msgId -> OutboxMessage -> idpk,
  # o en su defecto por el ciclo y dirección
  def find_proposal_by_target_or_cycle(target_msg_id, cycle_id, direction:)
    proposal = nil

    if target_msg_id.present?
      outbox = OutboxMessage.find_by(msg_id: target_msg_id)
      proposal_idpk = outbox&.idpk || target_msg_id
      proposal = Proposal.find_by(idpk: proposal_idpk)
    end

    proposal ||= Proposal.where(cycle_id: cycle_id, direction: direction)
                         .where(status: ["PENDING", "CONFIRMED"])
                         .first

    proposal
  end

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