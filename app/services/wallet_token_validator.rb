require "jwt"
require "net/http"
require "uri"

class WalletTokenValidator
  CACHE_KEY = "wallet:jwks".freeze

  def self.verify!(token)
    payload, = JWT.decode(
      token,
      nil,
      true,
      algorithms: ["ES256"],
      jwks: jwks
    )

    return false unless payload["exp"].is_a?(Numeric) && payload["exp"] > Time.current.to_i

    payload
  rescue JWT::DecodeError
    false
  end

  def self.jwks
    Rails.cache.fetch(CACHE_KEY, expires_in: 1.hour) do
      uri = URI.join("#{ENV["WALLET_URL"].to_s.chomp("/")}/", ".well-known/jwks.json")
      response = Net::HTTP.get_response(uri)
      raise JWT::DecodeError, "JWKS request failed with HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    end
  end
  private_class_method :jwks
end
