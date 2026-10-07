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

    # texto para el log y el detalle del nack: /events manda {error: CODIGO, detail: texto}
    def reason
      parsed = parsed_body
      text = parsed && (parsed['detail'] || parsed['error'])
      text ? text.to_s : body.to_s
    end

    # el codigo que mando la API (ej: UNKNOWN_TYPE), o nil
    def error_code
      parsed = parsed_body
      parsed && parsed['error']
    end

    private

    def parsed_body
      parsed = JSON.parse(body.to_s)
      parsed.is_a?(Hash) ? parsed : nil
    rescue JSON::ParserError
      nil
    end
  end

  def initialize(url)
    @events_uri = URI(url)
    @rejected_uri = URI("#{url.chomp('/')}/rejected")
    @outbox_url = "#{url.chomp('/')}/outbox"
  end

  def deliver(message)
    post(@events_uri, message)
  end

  def report_rejected(kind:, raw:, reason:)
    post(@rejected_uri, { 'kind' => kind, 'raw' => raw, 'reason' => reason })
  end

  # mensajes que la API quiere mandar a la central. si la API no responde bien, lista vacia y se prueba despues
  def pending_outbox
    result = send_request(Net::HTTP::Get.new(URI(@outbox_url)))
    list = result.saved? ? JSON.parse(result.body.to_s) : []
    list.is_a?(Array) ? list : []
  rescue JSON::ParserError
    []
  end

  def mark_outbox(id, status, reason = nil)
    post(URI("#{@outbox_url}/#{id}"), { 'status' => status, 'reason' => reason })
  end

  private

  def post(uri, payload)
    request = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
    request.body = JSON.generate(payload)
    send_request(request)
  end

  # nunca tira excepcion, si falla la red devuelve un Result sin status
  def send_request(request)
    response = http_for(request.uri).request(request)
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
