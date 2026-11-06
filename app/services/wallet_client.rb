require "json"
require "net/http"
require "uri"
require "securerandom"

class WalletClient
  Result = Struct.new(:success?, :status, :body, :retry_required?, keyword_init: true) do
    def parsed_body
      JSON.parse(body.to_s)
    rescue JSON::ParserError
      nil
    end
  end

  RETRYABLE_HTTP_STATUSES = [429, 502, 503, 504].freeze
  NETWORK_ERRORS = [
    Net::OpenTimeout,
    Net::ReadTimeout,
    Net::WriteTimeout,
    EOFError,
    Errno::ECONNRESET,
    Errno::ETIMEDOUT,
    SocketError,
    Errno::ECONNREFUSED
  ].freeze

  class RetryableFailure < StandardError; end

  def initialize(base_url: ENV["WALLET_URL"], api_key: ENV["CITY_API_KEY"])
    @base_url = base_url.to_s.chomp("/")
    @api_key = api_key
  end

  def propose_swap(give:, take:, memo:, expires_at:, idempotency_key:)
    payload = {
      give: give,
      take: take,
      memo: memo,
      expiresAt: expires_at
    }

    post("/swaps", payload, idempotency_key, enqueue_retry: true)
  end

  def accept_swap(swap_id:, idempotency_key:)
    post("/swaps/#{URI::DEFAULT_PARSER.escape(swap_id.to_s)}/accept", {}, idempotency_key)
  end

  def get_balance
    result = get("/balance")
    result&.parsed_body
  end

  def get_statement(limit: 50, after: nil)
    params = {}
    params[:limit] = limit if limit.present?
    params[:after] = after if after.present?

    path = "/statement"
    path += "?#{URI.encode_www_form(params)}" if params.any?
    get(path)&.parsed_body
  end

  def get_swap(swap_id)
    get("/swaps/#{URI::DEFAULT_PARSER.escape(swap_id.to_s)}")&.parsed_body
  end

  def cancel_swap(swap_id:, idempotency_key: SecureRandom.uuid)
    post("/swaps/#{URI::DEFAULT_PARSER.escape(swap_id.to_s)}/cancel", {}, idempotency_key)
  end

  private

  def get(path)
    uri = URI.join("#{@base_url}/", path.delete_prefix("/"))
    request = Net::HTTP::Get.new(uri)
    request["X-Api-Key"] = @api_key

    response = http_client(uri).request(request)
    return retry_read("HTTP #{response.code}", path) if response.is_a?(Net::HTTPTooManyRequests)
    return retry_read("HTTP #{response.code}", path) if RETRYABLE_HTTP_STATUSES.include?(response.code.to_i)

    Result.new(
      success?: response.is_a?(Net::HTTPSuccess),
      status: response.code.to_i,
      body: response.body,
      retry_required?: false
    )
  rescue *NETWORK_ERRORS => error
    retry_read(error.class.name, path)
  end

  def post(path, payload, idempotency_key, enqueue_retry: true)
    uri = URI.join("#{@base_url}/", path.delete_prefix("/"))
    request = Net::HTTP::Post.new(uri)
    request["X-Api-Key"] = @api_key
    request["Content-Type"] = "application/json"
    request["Idempotency-Key"] = idempotency_key

    # Bug fix: Convertir BigDecimal a Float explícitamente para que JSON no lo mande como string
    formatted_payload = payload.transform_values do |value|
      value.is_a?(BigDecimal) ? value.to_f.round(2) : value
    end

    request.body = JSON.generate(formatted_payload)
    response = http_client(uri).request(request)

    if response.is_a?(Net::HTTPTooManyRequests) || RETRYABLE_HTTP_STATUSES.include?(response.code.to_i)
      retry_required(
        "HTTP #{response.code}", 
        idempotency_key, 
        path, 
        formatted_payload, 
        enqueue_retry,
        retry_after: response["Retry-After"]
      )
      return Result.new(success?: false, status: response.code.to_i, body: response.body, retry_required?: true)
    end

    Result.new(
      success?: response.is_a?(Net::HTTPSuccess),
      status: response.code.to_i,
      body: response.body,
      retry_required?: false
    )
  rescue *NETWORK_ERRORS => error
    retry_required(error.class.name, idempotency_key, path, formatted_payload, enqueue_retry)
    Result.new(success?: false, status: nil, body: nil, retry_required?: true)
  end

  def http_client(uri)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = 5
    http.read_timeout = 10
    http
  end

  def retry_required(cause, idempotency_key, path, payload, enqueue_retry, retry_after: nil)
    Rails.logger.warn(
      "[WalletClient] #{path} falló por red/servidor (#{cause}); operation encolada con idempotency_key=#{idempotency_key}"
    )

    return unless enqueue_retry

    job = WalletRetryJob
    delay = retry_after_delay(retry_after)
    job = job.set(wait: delay) if delay
    
    if defined?(WalletRetryJob)
      job.perform_later(
        operation: "wallet_http",
        path: path,
        payload: payload,
        idempotency_key: idempotency_key
      )
    end
  end

  def retry_after_delay(value)
    return if value.blank?

    seconds = Float(value)
    seconds.positive? ? seconds.seconds : nil
  rescue ArgumentError, TypeError
    begin
      retry_at = Time.httpdate(value)
      [retry_at - Time.current, 0].max.seconds
    rescue ArgumentError, TypeError
      nil
    end
  end

  def retry_read(cause, path)
    Rails.logger.warn("[WalletClient] GET #{path} falló por red/servidor (#{cause}) y requiere reintento")
    nil
  end
end