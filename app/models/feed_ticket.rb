class FeedTicket
    TTL = 30.seconds
  
    def self.issue(user_sub: nil)
      ticket = SecureRandom.urlsafe_base64(32)
      Rails.cache.write(
        cache_key(ticket),
        { user_sub: user_sub, issued_at: Time.current.iso8601 },
        expires_in: TTL
      )
      ticket
    end
  
    # Valida y consume el ticket en una sola operación (un solo uso)
    def self.consume!(ticket)
      return nil if ticket.blank?
  
      key = cache_key(ticket)
      data = Rails.cache.read(key)
      return nil unless data
  
      Rails.cache.delete(key)
      data
    end
  
    def self.cache_key(ticket)
      "sse_feed_ticket:#{ticket}"
    end
end