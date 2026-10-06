require 'minitest/autorun'
require 'json'
require_relative '../lib/message_validator'
 
# correr desde /connector: ruby test/message_validator_test.rb
class MessageValidatorTest < Minitest::Test

  def valid_message(changes = {})
    {
      'msgId' => '11111111-1111-4111-8111-111111111111',
      'idpk' => '22222222-2222-4222-8222-222222222222',
      'type' => 'transfer',
      'timestamp' => '2026-10-06T14:00:00Z',
      'sender' => 'central',
      'cycleId' => 'cycle-9431',
      'data' => { 'quantity' => 508_145 }
    }.merge(changes)
  end
 
  def without(field)
    message = valid_message
    message.delete(field)
    message
  end
 
  def check(message)
    MessageValidator.check(JSON.generate(message))
  end
 
  def assert_nack(decision, reason, code)
    assert_equal :nack, decision.action
    assert_equal reason, decision.reason
    assert_equal code, decision.code
  end
 
  # mensajes validos
 
  def test_mensaje_valido_se_acepta_y_pide_ack
    decision = check(valid_message)
    assert_equal :accept, decision.action
    assert decision.send_ack
  end
 
  def test_campos_extra_se_ignoran
    decision = check(valid_message('campoNuevo' => 123))
    assert_equal :accept, decision.action
  end
 
  def test_demand_statement_con_cantidad_negativa_es_valido
    data = { 'balance' => { 'quantity' => -1500, 'valuePerKwh' => 215 } }
    decision = check(valid_message('type' => 'demand-statement', 'data' => data))
    assert_equal :accept, decision.action
  end
 
  def test_distance_table_valida_no_necesita_cycle_id
    data = { 'distances' => { 'HGW' => { 'distance' => 62_763_183, 'transportCost' => 0.0034, 'enabled' => true } } }
    message = without('cycleId').merge('type' => 'distance-table', 'data' => data)
    assert_equal :accept, check(message).action
  end
 
  # descartes
 
  def test_texto_que_no_es_json_se_descarta
    assert_equal :discard, MessageValidator.check('esto no es json').action
  end
 
  def test_json_que_no_es_un_objeto_se_descarta
    assert_equal :discard, MessageValidator.check('[1, 2, 3]').action
  end
 
  def test_sin_msg_id_se_descarta
    assert_equal :discard, check(without('msgId')).action
  end
 
  # nack
 
  def test_sin_idpk_es_malformed
    assert_nack check(without('idpk')), 'MALFORMED_MESSAGE', 422
  end
 
  def test_timestamp_invalido_es_malformed
    assert_nack check(valid_message('timestamp' => 'ayer')), 'MALFORMED_MESSAGE', 422
  end
 
  def test_idpk_igual_a_msg_id
    same = '11111111-1111-4111-8111-111111111111'
    assert_nack check(valid_message('idpk' => same)), 'IDPK_EQUALS_MSGID', 422
  end
 
  def test_tipo_desconocido
    assert_nack check(valid_message('type' => 'tipo-inventado')), 'UNKNOWN_TYPE', 400
  end
 
  def test_contenido_invalido_es_malformed
    decision = check(valid_message('data' => { 'quantity' => 'mucho' }))
    assert_nack decision, 'MALFORMED_MESSAGE', 422
    assert_equal 'data.quantity debe ser un número', decision.detail
  end
 
  def test_mensaje_de_ciclo_sin_cycle_id_es_malformed
    assert_nack check(without('cycleId')), 'MALFORMED_MESSAGE', 422
  end
 
  # respuestas de la central (no se responden)
 
  def test_ack_de_la_central_se_acepta_sin_responder
    decision = check(valid_message('type' => 'ack', 'data' => { 'target' => 'abc' }))
    assert_equal :accept, decision.action
    refute decision.send_ack
  end
 
  def test_nack_invalido_de_la_central_se_descarta_sin_responder
    message = without('idpk').merge('type' => 'nack')
    assert_equal :discard, check(message).action
  end
end