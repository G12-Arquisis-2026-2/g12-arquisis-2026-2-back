# trade-recorded: la central lo manda al comprador y al vendedor tras cada swap KWH/CR, con el
# transporte que cobró al comprador. Se guarda por ciclo para el resumen (RF01).
class TradeRecordProcessorService
  # Devuelve true si se guardó y false si el idpk ya existía.
  def self.call(payload)
    ProcessedMessage.process_once(payload) { TradeRecord.create!(attributes(payload)) }
  end

  def self.attributes(payload)
    data = payload.fetch("data")
    {
      idpk: payload.fetch("idpk"),
      msg_id: payload.fetch("msgId"),
      cycle_id: payload.fetch("cycleId"),
      swap_id: data.fetch("swapId"),
      offer_id: data.fetch("offerId"),
      seller: data.fetch("seller"),
      buyer: data.fetch("buyer"),
      quantity: data.fetch("quantity"),
      price_per_energy: data.fetch("pricePerEnergy"),
      energy_total: data.fetch("energyTotal"),
      transport_per_energy: data.fetch("transportPerEnergy"),
      transport_total: data.fetch("transportTotal"),
      route_enabled: data.fetch("routeEnabled"),
      recorded_at: payload["timestamp"],
      raw_payload: payload
    }
  end

  private_class_method :attributes
end
