class StructuredLogger
    def self.info(message, cycle_id: nil, swap_id: nil, idpk: nil, **extra)
      log(:info, message, cycle_id: cycle_id, swap_id: swap_id, idpk: idpk, **extra)
    end
  
    def self.warn(message, cycle_id: nil, swap_id: nil, idpk: nil, **extra)
      log(:warn, message, cycle_id: cycle_id, swap_id: swap_id, idpk: idpk, **extra)
    end
  
    def self.error(message, cycle_id: nil, swap_id: nil, idpk: nil, **extra)
      log(:error, message, cycle_id: cycle_id, swap_id: swap_id, idpk: idpk, **extra)
    end
  
    def self.log(level, message, cycle_id: nil, swap_id: nil, idpk: nil, **extra)
      entry = {
        timestamp: Time.current.iso8601(3),
        level: level.to_s.upcase,
        service: 'city-backend',
        message: message,
        cycleId: cycle_id,
        swapId: swap_id,
        idpk: idpk
      }.merge(extra).compact
  
      Rails.logger.public_send(level, entry.to_json)
    end
end