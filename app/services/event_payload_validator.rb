# Revisa que un evento traiga los campos requeridos para su tipo antes de procesarlo.
class EventPayloadValidator
  class MalformedMessage < ArgumentError; end

  TYPES_WITH_CYCLE = %w[transfer demand-statement status-statement give take].freeze
  # Respuestas de la central: data es opcional.
  REPLY_TYPES = %w[ack nack error].freeze

  def self.validate!(payload)
    type = payload["type"]

    require_value!(payload, "idpk", "")
    require_value!(payload, "cycleId", "") if TYPES_WITH_CYCLE.include?(type)
    return if REPLY_TYPES.include?(type)

    data = require_hash!(payload, "data", "")

    case type
    when "transfer"
      require_value!(data, "quantity", "data.")
    when "give", "take"
      %w[target energy pricePerEnergy].each { |key| require_value!(data, key, "data.") }
    when "status-statement"
      require_value!(data, "validUntil", "data.")
      energy = require_hash!(data, "energy", "data.")
      %w[generationCapacity consumption generationCost].each { |key| require_value!(energy, key, "data.energy.") }
    when "distance-table"
      distances = require_hash!(data, "distances", "data.")
      distances.each_key do |code|
        route = require_hash!(distances, code, "data.distances.")
        %w[distance transportCost enabled].each { |key| require_value!(route, key, "data.distances.#{code}.") }
      end
    end
  end

  def self.require_value!(hash, key, path)
    value = hash[key]
    raise MalformedMessage, "missing field #{path}#{key}" if value.nil? || value == ""

    value
  end

  def self.require_hash!(hash, key, path)
    value = require_value!(hash, key, path)
    raise MalformedMessage, "#{path}#{key} must be an object" unless value.is_a?(Hash)

    value
  end

  private_class_method :require_value!, :require_hash!
end
