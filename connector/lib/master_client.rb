require 'json'
require 'net/http'
require 'uri'

class MasterClient
  # timeouts para no quedar esperando para siempre si la API se cuelga
  OPEN_TIMEOUT = 5
  READ_TIMEOUT = 10

  # status nil = no hubo respuesta (error de red)
  Result = Struct.new(:status, :body) do
    def saved?
      (200..299).cover?(status)
    end

    def invalid?
      status == 422
    end

    def reason
      parsed = JSON.parse(body.to_s)
      text = parsed.is_a?(Hash) && (parsed['error'] || parsed['detail'])
      text ? text.to_s : body.to_s
    rescue JSON::ParserError
      body.to_s
    end
  end

  def initialize(url)
    @events_uri = URI(url)
    @rejected_uri = URI("#{url.chomp('/')}/rejected")
  end

  def deliver(message)
    post(@events_uri, message)
  end

  def report_rejected(kind:, raw:, reason:)
    post(@rejected_uri, { 'kind' => kind, 'raw' => raw, 'reason' => reason })
  end

  private

  # nunca tira excepcion, si falla la red devuelve un Result sin status
  def post(uri, payload)
    request = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
    request.body = JSON.generate(payload)
    response = http_for(uri).request(request)
    Result.new(response.code.to_i, response.body)
  rescue StandardError => e
    Result.new(nil, "#{e.class}: #{e.message}")
  end

  def http_for(uri)
    http = Net::HTTP.new(uri.hostname, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.open_timeout = OPEN_TIMEOUT
    http.read_timeout = READ_TIMEOUT
    http
  end
end
