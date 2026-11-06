require 'minitest/autorun'
require 'json'
require_relative '../lib/message_validator'
require_relative 'support/samples'

# recorre los ejemplos oficiales del curso (test/fixtures/contracts-v3.0.2, ver su README)
# correr desde /connector: ruby test/contract_examples_test.rb
class ContractExamplesTest < Minitest::Test
  ROOT = File.expand_path('fixtures/contracts-v3.0.2/amqp', __dir__)

  # fallan solo por un campo extra: nosotros como receptores los aceptamos igual
  EXTRA_FIELD_KEYWORDS = %w[additionalProperties unevaluatedProperties].freeze
  # este falla por additionalProperties pero el motivo es la clave "hgw" (no es un codigo de ciudad)
  NOT_AN_EXTRA_FIELD = %w[distance-table/lowercase-destination.json].freeze

  def examples(kind)
    Dir[File.join(ROOT, '*', kind, '*.json')].sort.map do |path|
      ["#{File.basename(File.dirname(path, 2))}/#{File.basename(path)}", path]
    end
  end

  # el user_id con que lo publicaria su emisor real
  def user_for(message)
    return "city.#{message['cityId']}" if message['cityId']

    message['type'] == 'market-closed' ? nil : 'central'
  end

  # los del mercado llegan con la routing key con que el broker los entregaria
  def check(message, user_id)
    queue = MessageValidator::MARKET_TYPES.include?(message['type']) ? :market : :city
    MessageValidator.check(JSON.generate(message), user_id, queue: queue,
                                                            routing_key: Samples.market_routing_key(message))
  end

  # aplica set y unset (rutas JSON pointer) sobre una copia del ejemplo base
  def mutate(base, mutation)
    message = JSON.parse(JSON.generate(base))
    (mutation['set'] || {}).each { |path, value| parent_of(message, path, create: true)[key_of(path)] = value }
    (mutation['unset'] || []).each { |path| parent_of(message, path).delete(key_of(path)) }
    message
  end

  def parent_of(message, path, create: false)
    keys(path)[0..-2].reduce(message) { |hash, key| create ? (hash[key] ||= {}) : hash.fetch(key) }
  end

  def key_of(path)
    keys(path).last
  end

  def keys(path)
    path.split('/').drop(1).map { |part| part.gsub('~1', '/').gsub('~0', '~') }
  end

  # [nombre, mensaje mutado, user_id del emisor del ejemplo base, keyword esperada]
  def invalid_examples
    examples('invalid').map do |name, path|
      mutation = JSON.parse(File.read(path))
      base = JSON.parse(File.read(File.expand_path(mutation['base'], File.dirname(path))))
      [name, mutate(base, mutation), user_for(base), mutation.dig('expect', 'keyword')]
    end
  end

  def extra_field_only?(name, keyword)
    EXTRA_FIELD_KEYWORDS.include?(keyword) && !NOT_AN_EXTRA_FIELD.include?(name)
  end

  def test_hay_ejemplos_de_cada_tipo_que_recibimos
    types = Dir[File.join(ROOT, '*')].map { |dir| File.basename(dir) }.sort
    expected = (MessageValidator::TYPES_WITH_ACK + MessageValidator::NO_REPLY_TYPES +
                MessageValidator::MARKET_TYPES).sort
    assert_equal expected, types
  end

  def test_todos_los_ejemplos_validos_se_aceptan
    list = examples('valid')
    assert_operator list.size, :>=, 50
    list.each do |name, path|
      message = JSON.parse(File.read(path))
      decision = check(message, user_for(message))
      assert_equal :accept, decision.action, "#{name}: #{decision.detail}"
    end
  end

  # campo obligatorio que falta, tipo incorrecto, formato, patron, minimo o par reason/code
  def test_los_invalidos_por_algo_que_exigimos_se_rechazan
    cases = invalid_examples.reject { |name, _, _, keyword| extra_field_only?(name, keyword) }
    assert_operator cases.size, :>=, 50
    cases.each do |name, message, user_id, _|
      decision = check(message, user_id)
      refute_equal :accept, decision.action, name
      assert_equal 'MALFORMED_MESSAGE', decision.reason, "#{name}: #{decision.detail}"
    end
  end

  # lo que emite la central es "cerrado" en los schemas, pero como receptores no rechazamos
  # un campo extra. la excepcion es un cityId en un mensaje de la central: sender y cityId a la
  # vez es emisor no permitido (caso 3 de la ayudante), y el schema tambien lo invalida
  def test_un_campo_extra_no_hace_rechazar_el_mensaje
    invalid_examples.select { |name, _, _, keyword| extra_field_only?(name, keyword) }.each do |name, message, user_id, _|
      decision = check(message, user_id)
      if message['sender'] && message['cityId']
        refute_equal :accept, decision.action, name
      else
        assert_equal :accept, decision.action, "#{name}: #{decision.detail}"
      end
    end
  end
end
