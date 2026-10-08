class StatusStatementProcessorService
  def self.call(payload)
    data = payload.fetch("data")
    energy = data.fetch("energy")

    ProcessedMessage.process_once(payload) do
      cycle = Cycle.find_or_initialize_by(cycle_id: payload.fetch("cycleId"))
      cycle.assign_attributes(
        generation_capacity: energy.fetch("generationCapacity"),
        consumption: energy.fetch("consumption"),
        generation_cost: energy.fetch("generationCost"),
        valid_until: data.fetch("validUntil")
      )
      cycle.save!
    end
  end
end
