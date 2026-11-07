# imbalance-settlement: liquidación de la central al cierre del ciclo. Se guarda por ciclo para el
# resumen (RF01) y sigue quedando en AuditLog como IMBALANCE_SETTLEMENT, como antes.
class ImbalanceSettlementProcessorService
  # Devuelve true si se guardó y false si el idpk ya existía.
  def self.call(payload)
    ProcessedMessage.process_once(payload) do
      ImbalanceSettlement.create!(attributes(payload))
      AuditedEventService.record!(payload)
    end
  end

  def self.attributes(payload)
    data = payload.fetch("data")
    {
      idpk: payload.fetch("idpk"),
      msg_id: payload.fetch("msgId"),
      cycle_id: payload.fetch("cycleId"),
      settlement_id: data.fetch("settlementId"),
      kwh_held: data.fetch("kwhHeld"),
      deficit: data.fetch("deficit"),
      coverage: data.fetch("coverage"),
      price_per_energy: data.fetch("pricePerEnergy"),
      total: data.fetch("total"),
      balance_after: data.fetch("balanceAfter"),
      settled_at: payload["timestamp"],
      raw_payload: payload
    }
  end

  private_class_method :attributes
end
