require 'json'
require_relative 'rate_limiter'

# inicia las sagas de AD7 en Step Functions desde las filas step_functions del outbox (ADR8).
# el nombre de la ejecucion es el idpk: si un reenvio llega a AWS, responde ExecutionAlreadyExists y no
# se crea una segunda saga
class SagaStarter
  EXCHANGE = 'step_functions'.freeze
  ROLES = %w[seller buyer].freeze
  NAME = /\A[A-Za-z0-9_-]{1,80}\z/
  # la cuota de StartExecution es de cientos por segundo; cada saga sale de un bid, y los bids ya salen a lo
  # sumo 50 por minuto. 60 por minuto deja pasar todo lo normal y frena un bucle antes de que llegue a AWS
  LIMIT_PER_MINUTE = 60
  # tras throttling o un error de red no se insiste en cada vuelta de 2 s
  PAUSE_SECONDS = 30
  # reintentarlos daria lo mismo: la fila queda fallida
  FINAL_ERRORS = %w[AccessDeniedException StateMachineDoesNotExist InvalidName InvalidExecutionInput
                    InvalidArn StateMachineDeleting ValidationException].freeze

  # arns: { 'seller' => arn, 'buyer' => arn }. client: Aws::States::Client (o uno de prueba)
  def initialize(client:, arns:, log:, enabled: false, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                 limiter: RateLimiter.new(limit: LIMIT_PER_MINUTE, window: 60, clock: clock))
    @client = client
    @arns = arns
    @log = log
    @enabled = enabled
    @clock = clock
    @limiter = limiter
    @waiting_logged = {}
    @paused_until = nil
  end

  # routing_key: la maquina segun la fila; tiene que coincidir con data.role
  def problem(data, routing_key)
    return 'la saga no trae data' unless data.is_a?(Hash)
    return "#{data['role'].inspect} no es una máquina (seller o buyer)" unless ROLES.include?(data['role'])
    return "la routing key #{routing_key} no coincide con la máquina #{data['role']}" unless routing_key == data['role']
    return "#{data['name'].inspect} no sirve como nombre de ejecución" unless data['name'].to_s.match?(NAME)

    'el input de la saga no es un objeto' unless data['input'].is_a?(Hash)
  end

  # :sent, :pending o [:failed, motivo]
  def start(id, data)
    return waiting(id, data) unless @enabled
    return :pending if paused?
    return missing_arn(id, data) if @arns[data['role']].to_s.empty?
    return limited unless @limiter.take

    execute(data)
  end

  private

  def execute(data)
    response = @client.start_execution(state_machine_arn: @arns[data['role']], name: data['name'],
                                       input: JSON.generate(data['input']))
    @log.call("Saga #{data['role']} #{data['name']} iniciada (#{response.execution_arn}).")
    :sent
  rescue StandardError => e
    classify(e, data)
  end

  def classify(error, data)
    code = error.respond_to?(:code) ? error.code.to_s : ''
    return already_started(data) if code == 'ExecutionAlreadyExists'
    return final(code, data) if FINAL_ERRORS.include?(code)

    pause("Step Functions no respondió bien (#{code.empty? ? error.class : code})")
  end

  def final(code, data)
    reason = "Step Functions respondió #{code}"
    @log.call("Saga #{data['role']} #{data['name']}: #{reason}, queda fallida.")
    [:failed, reason]
  end

  def already_started(data)
    @log.call("Saga #{data['role']} #{data['name']} ya existía (ExecutionAlreadyExists), se marca enviada.")
    :sent
  end

  def pause(text)
    @paused_until = @clock.call + PAUSE_SECONDS
    @log.call("#{text}: las sagas quedan pendientes y se reintentan en #{PAUSE_SECONDS} s.")
    :pending
  end

  def paused?
    @paused_until && @clock.call < @paused_until
  end

  def limited
    pause("Cupo de #{LIMIT_PER_MINUTE} sagas por minuto agotado")
  end

  def missing_arn(id, data)
    log_once(id, "Falta el ARN de la máquina #{data['role']}, la saga #{data['name']} (pendiente #{id}) espera.")
  end

  def waiting(id, data)
    log_once(id, "SAGA_START_ENABLED apagado, la saga #{data['role']} #{data['name']} (pendiente #{id}) espera.")
  end

  def log_once(id, text)
    @log.call(text) unless @waiting_logged[id]
    @waiting_logged[id] = true
    :pending
  end
end
