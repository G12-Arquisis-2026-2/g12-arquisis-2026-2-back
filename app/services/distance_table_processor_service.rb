class DistanceTableProcessorService
  def self.call(payload)
    distances = payload.fetch("data").fetch("distances")
    rows = distances.map do |destination_code, attributes|
      {
        destination_code: destination_code,
        distance: attributes.fetch("distance"),
        transport_cost: attributes.fetch("transportCost"),
        enabled: attributes.fetch("enabled")
      }
    end

    return 0 if rows.empty?

    DistanceTable.upsert_all(
      rows,
      unique_by: :index_distance_tables_on_destination_code,
      update_only: %i[distance transport_cost enabled]
    )

    rows.size
  end
end