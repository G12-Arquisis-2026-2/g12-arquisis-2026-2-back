class DistanceTableProcessorService
  # Devuelve la cantidad de destinos procesados, o false si el idpk ya existía.
  def self.call(payload)
    distances = payload.fetch("data").fetch("distances")

    processed = ProcessedMessage.process_once(payload) do
      distances.each do |destination_code, attributes|
        destination = DistanceTable.find_or_initialize_by(destination_code: destination_code)
        destination.assign_attributes(
          distance: attributes.fetch("distance"),
          transport_cost: attributes.fetch("transportCost"),
          enabled: attributes.fetch("enabled")
        )
        destination.save!
      end
    end

    processed && distances.size
  end
end
