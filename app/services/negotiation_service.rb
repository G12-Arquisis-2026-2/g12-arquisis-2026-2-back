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

  # 3. Cálculo de capacidad vendible: max(0, generationCapacity - consumption)
  def self.available_capacity(generation_capacity, consumption)
    [0, generation_capacity.to_f - consumption.to_f].max
  end

  def self.calculate_quantity(pricePerEnergy, energy)
    (energy.to_f * pricePerEnergy).round(2)
  end

  # 4. Construcción y validación de propuesta de negociación
  def self.build_proposal(cycle_id:, direction:, energy:, existing_idpk: nil)
    cycle = Cycle.find_by(cycle_id: cycle_id)
    raise ActiveRecord::RecordNotFound, "Ciclo no encontrado: #{cycle_id}" unless cycle

    generation_cost = cycle.generation_cost
    max_cap = calculate_price_cap(generation_cost)
    price = calculate_price(direction, generation_cost)
    quantity = calculate_quantity(price, energy)
    generation_capacity = cycle.generation_capacity
    consumption = cycle.consumption

    if energy > available_capacity(generation_capacity, consumption)
      raise OverCapacityError, "La cantidad (#{energy}) supera la capacidad disponible (#{available_capacity(generation_capacity, consumption)}) para el ciclo #{cycle_id}"
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
        quantity: quantity,
        pricePerEnergy: price
      },
      timestamp: Time.current.iso8601
    }
  end
end