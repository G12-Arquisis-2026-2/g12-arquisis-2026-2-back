# Revisa que un evento traiga los campos requeridos para su tipo antes de procesarlo.
class EventPayloadValidator
  class MalformedMessage < ArgumentError; end

  TYPES_WITH_CYCLE = %w[transfer demand-statement status-statement give take].freeze
  # Respuestas de la central: data es opcional.
  REPLY_TYPES = %w[ack nack error].freeze
  # Número JSON o string numérico ("100", "-4", "100.5", "1e3"). Es lo que acepta BigDecimal en el ledger.
  NUMERIC_STRING = /\A[+-]?\d+(\.\d+)?([eE][+-]?\d+)?\z/

  def self.validate!(payload)
    type = payload["type"]

    require_value!(payload, "idpk", "")
    require_value!(payload, "cycleId", "") if TYPES_WITH_CYCLE.include?(type)
    return if REPLY_TYPES.include?(type)

    data = require_hash!(payload, "data", "")

    case type
    when "transfer"
      require_number!(data, "quantity", "data.")
    when "demand-statement"
      validate_demand_statement!(data)
    when "give", "take"
      require_value!(data, "target", "data.")
      %w[energy pricePerEnergy].each { |key| require_number!(data, key, "data.") }
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

  def self.require_number!(hash, key, path)
    value = require_value!(hash, key, path)
    numeric = value.is_a?(Numeric) ? value.finite? : value.is_a?(String) && value.match?(NUMERIC_STRING)
    raise MalformedMessage, "#{path}#{key} must be a number" unless numeric

    value
  end

  # Mismos formatos que lee LedgerProcessorService: data.quantity / data.valuePerKwh,
  # data.balance como objeto { quantity, valuePerKwh } o data.balance como número.
  def self.validate_demand_statement!(data)
    balance = data["balance"]
    if data["quantity"].nil? && balance.is_a?(Hash)
      require_number!(balance, "quantity", "data.balance.")
    elsif data["quantity"].nil? && !balance.nil?
      require_number!(data, "balance", "data.")
    else
      require_number!(data, "quantity", "data.")
    end

    if data["valuePerKwh"].nil? && balance.is_a?(Hash)
      require_number!(balance, "valuePerKwh", "data.balance.")
    else
      require_number!(data, "valuePerKwh", "data.")
    end
  end

  def self.require_hash!(hash, key, path)
    value = require_value!(hash, key, path)
    raise MalformedMessage, "#{path}#{key} must be an object" unless value.is_a?(Hash)

    value
  end

  private_class_method :require_value!, :require_number!, :require_hash!, :validate_demand_statement!
end
