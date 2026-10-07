class NegotiationService
  class PriceCapExceededError < StandardError; end
  class OverCapacityError < StandardError; end

  # 1. Cálculo de precio de oferta según dirección ('take' o 'give')
  def self.calculate_price(direction, generation_cost)
    cost = generation_cost.to_f
    case direction.to_s
    when 'take'
      cost # 'take' se liquida al generationCost
    when 'give'
      (1.05 * cost).round(2)
    else
      raise ArgumentError, "Dirección de negociación no válida: #{direction}"
    end
  end

  # 2. Cálculo del tope máximo permitido de precio para el ciclo
  def self.calculate_price_cap(generation_cost)
    (1.05 * generation_cost.to_f).round(2)
  end

  # 3. Energía vendible que queda en el ciclo: max(0, generationCapacity - consumption) menos lo ya
  # vendido en ese ciclo (Enunciado § El tope de la oferta: así calcula la central data.spare)
  def self.available_capacity(generation_capacity, consumption, sold = 0)
    [0, [0, generation_capacity.to_f - consumption.to_f].max - sold.to_f].max
  end

  # Energía ya vendida en el ciclo: los give que la central nos confirmó (quedan en el ledger con
  # energy_change negativo). Con excluding_idpk no cuenta las confirmaciones de esa misma operación:
  # si se reintenta un give porque nunca llegó su transfer, esa venta no fue real (Enunciado § Pago)
  # y el reintento no debe chocar contra su propia energía.
  def self.sold_energy(cycle_id, excluding_idpk: nil)
    gives = Transaction.where(cycle_id: cycle_id, operation_type: "give")
    if excluding_idpk.present?
      own_msg_ids = OutboxMessage.where(idpk: excluding_idpk).pluck(:msg_id) + [excluding_idpk]
      gives = gives.where("COALESCE(raw_data->'data'->>'target', '') NOT IN (?)", own_msg_ids)
    end
    -gives.sum(:energy_change).to_f
  end

  # 4. Construcción y validación de propuesta de negociación
  def self.build_proposal(cycle_id:, direction:, energy:, existing_idpk: nil)
    cycle = Cycle.find_by(cycle_id: cycle_id)
    raise ActiveRecord::RecordNotFound, "Ciclo no encontrado: #{cycle_id}" unless cycle

    energy = energy.to_f
    generation_cost = cycle.generation_cost
    max_cap = calculate_price_cap(generation_cost)
    price = calculate_price(direction, generation_cost)

    # OVER_CAPACITY solo aplica a give: comprar (take) no usa capacidad propia
    if direction.to_s == 'give'
      sold = sold_energy(cycle_id, excluding_idpk: existing_idpk)
      spare = available_capacity(cycle.generation_capacity, cycle.consumption, sold)
      if energy > spare
        raise OverCapacityError, "La energía (#{energy}) supera la capacidad vendible restante (#{spare}) para el ciclo #{cycle_id}"
      end
    end

    # Validar tope de precio para evitar rechazo PRICE_ABOVE_CAP
    if price > max_cap
      raise PriceCapExceededError, "El precio (#{price}) supera el tope de #{max_cap} para el ciclo #{cycle_id}"
    end

    {
      idpk: existing_idpk || SecureRandom.uuid, # Idempotencia: reutiliza idpk si es reintento
      msgId: SecureRandom.uuid,
      type: "negotiation-proposal",
      cycleId: cycle_id,
      data: {
        direction: direction,
        # energía (kWh), no monto: el monto round2(energy × pricePerEnergy) solo va en el transfer de pago
        quantity: energy,
        pricePerEnergy: price
      },
      timestamp: Time.current.iso8601
    }
  end
end
