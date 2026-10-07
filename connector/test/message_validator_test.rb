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
 
  def assert_accept_with_ack(decision)
    assert_equal :accept, decision.action
    assert decision.send_ack
  end

 
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
 
 
  def test_texto_que_no_es_json_se_descarta
    assert_equal :discard, MessageValidator.check('esto no es json').action
  end
 
  def test_json_que_no_es_un_objeto_se_descarta
    assert_equal :discard, MessageValidator.check('[1, 2, 3]').action
  end
 
  def test_sin_msg_id_se_descarta
    assert_equal :discard, check(without('msgId')).action
  end
 
 
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
 
 
  def test_ack_de_la_central_se_acepta_sin_responder
    decision = check(valid_message('type' => 'ack', 'data' => { 'target' => 'abc' }))
    assert_equal :accept, decision.action
    refute decision.send_ack
  end
 
  def test_nack_invalido_de_la_central_se_descarta_sin_responder
    message = without('idpk').merge('type' => 'nack')
    assert_equal :discard, check(message).action
  end


  def test_sin_type_es_malformed
    decision = check(without('type'))
    assert_nack decision, 'MALFORMED_MESSAGE', 422
    assert_equal 'falta el campo type', decision.detail
  end

  def test_sin_timestamp_es_malformed
    decision = check(without('timestamp'))
    assert_nack decision, 'MALFORMED_MESSAGE', 422
    assert_equal 'falta el campo timestamp', decision.detail
  end


  def test_sin_data_es_malformed
    decision = check(without('data'))
    assert_nack decision, 'MALFORMED_MESSAGE', 422
    assert_equal 'data debe ser un objeto', decision.detail
  end

  def test_data_que_no_es_un_objeto_es_malformed
    ['texto', 5, [1, 2], nil].each do |data|
      assert_nack check(valid_message('data' => data)), 'MALFORMED_MESSAGE', 422
    end
  end

  def test_campo_extra_dentro_de_data_se_ignora
    decision = check(valid_message('data' => { 'quantity' => 10, 'campoNuevo' => 'x' }))
    assert_equal :accept, decision.action
  end


  def test_status_statement_valido
    data = { 'energy' => { 'generationCapacity' => 900, 'consumption' => 700.5, 'generationCost' => 12 } }
    assert_accept_with_ack check(valid_message('type' => 'status-statement', 'data' => data))
  end

  def test_status_statement_sin_consumption_es_malformed
    data = { 'energy' => { 'generationCapacity' => 900, 'generationCost' => 12 } }
    decision = check(valid_message('type' => 'status-statement', 'data' => data))
    assert_nack decision, 'MALFORMED_MESSAGE', 422
    assert_equal 'data.energy.consumption debe ser un número', decision.detail
  end

  def test_demand_statement_valido
    data = { 'balance' => { 'quantity' => 1500, 'valuePerKwh' => 215 } }
    assert_accept_with_ack check(valid_message('type' => 'demand-statement', 'data' => data))
  end

  def test_demand_statement_sin_balance_es_malformed
    decision = check(valid_message('type' => 'demand-statement', 'data' => { 'quantity' => 1500 }))
    assert_nack decision, 'MALFORMED_MESSAGE', 422
    assert_equal 'data.balance debe ser un objeto', decision.detail
  end

  def test_give_y_take_validos
    data = { 'target' => 'HGW', 'energy' => 300, 'pricePerEnergy' => 1.5 }
    %w[give take].each do |type|
      assert_accept_with_ack check(valid_message('type' => type, 'data' => data))
    end
  end

  def test_give_sin_target_es_malformed
    data = { 'energy' => 300, 'pricePerEnergy' => 1.5 }
    decision = check(valid_message('type' => 'give', 'data' => data))
    assert_nack decision, 'MALFORMED_MESSAGE', 422
    assert_equal 'falta el campo data.target', decision.detail
  end

  def test_take_con_energy_de_texto_es_malformed
    data = { 'target' => 'HGW', 'energy' => '300', 'pricePerEnergy' => 1.5 }
    decision = check(valid_message('type' => 'take', 'data' => data))
    assert_nack decision, 'MALFORMED_MESSAGE', 422
    assert_equal 'data.energy debe ser un número', decision.detail
  end

  def test_distance_table_con_enabled_de_texto_es_malformed
    data = { 'distances' => { 'HGW' => { 'distance' => 1, 'transportCost' => 0.1, 'enabled' => 'si' } } }
    decision = check(valid_message('type' => 'distance-table', 'data' => data))
    assert_nack decision, 'MALFORMED_MESSAGE', 422
    assert_equal 'data.distances.HGW.enabled debe ser true o false', decision.detail
  end

  def test_distance_table_sin_distances_es_malformed
    decision = check(valid_message('type' => 'distance-table', 'data' => { 'routes' => [] }))
    assert_nack decision, 'MALFORMED_MESSAGE', 422
  end


  def test_nack_y_error_de_la_central_se_aceptan_sin_responder
    %w[nack error].each do |type|
      decision = check(valid_message('type' => type, 'data' => { 'target' => 'abc' }))
      assert_equal :accept, decision.action
      refute decision.send_ack
    end
  end


  def test_byte_invalido_dentro_de_un_texto_se_descarta
    body = "{\"msgId\":\"a\xFF\"}"
    assert_equal :discard, MessageValidator.check(body).action
    assert_equal :discard, MessageValidator.check(body.b).action
  end

  def test_mensaje_valido_con_un_byte_invalido_se_descarta
    body = JSON.generate(valid_message).sub('central', "centr\xFFl".b.force_encoding('UTF-8'))
    assert_equal :discard, MessageValidator.check(body.b).action
  end

  def test_mensaje_valido_que_llega_como_bytes_se_acepta
    body = JSON.generate(valid_message('sender' => 'centralñ')).b
    assert_equal :accept, MessageValidator.check(body).action
  end

  def test_ninguna_entrada_hace_que_check_lance_una_excepcion
    entradas = [
      nil, '', ' ', 'null', '5', '"texto"', '{}', '{', "\x00", "\xFF\xFE".b, 42, :simbolo, [], {},
      '[' * 500, '{"msgId":{"a":1}}', '{"msgId":"a","type":["ack"]}',
      JSON.generate(valid_message('timestamp' => '2026-99-99T99:99:99Z')),
      JSON.generate(valid_message('timestamp' => 12)),
      JSON.generate(valid_message('type' => 'distance-table', 'data' => { 'distances' => [1] })),
      JSON.generate(valid_message('type' => 'distance-table', 'data' => { 'distances' => { 'A' => nil } })),
      JSON.generate(valid_message('type' => 'give', 'data' => { 'target' => 5 }))
    ]
    entradas.each do |entrada|
      decision = MessageValidator.check(entrada)
      assert_includes %i[discard nack accept], decision.action
    end
  end
end