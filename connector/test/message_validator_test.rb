require 'minitest/autorun'
require 'json'
require_relative '../lib/message_validator'
require_relative 'support/samples'

# correr desde /connector: ruby test/message_validator_test.rb
# los mensajes base son los ejemplos oficiales (test/support/samples.rb)
class MessageValidatorTest < Minitest::Test
  def sample(type, changes = {})
    Samples.message(type, changes)
  end

  def without(field, message = sample('transfer'))
    Samples.without(field, message)
  end

  # por omision el user_id es el que corresponde al emisor del mensaje
  def check(message, user_id = Samples.user_for(message), queue: :city)
    MessageValidator.check(JSON.generate(message), user_id, queue: queue)
  end

  def assert_nack(decision, reason, code)
    assert_equal :nack, decision.action, decision.detail
    assert_equal reason, decision.reason
    assert_equal code, decision.code
  end

  def assert_malformed(decision)
    assert_nack decision, 'MALFORMED_MESSAGE', 422
  end

  def assert_accept_with_ack(decision)
    assert_equal :accept, decision.action, decision.detail
    assert decision.send_ack
  end

  def assert_accept_without_reply(decision)
    assert_equal :accept, decision.action, decision.detail
    refute decision.send_ack
  end

  def assert_discard(decision)
    assert_equal :discard, decision.action, decision.detail
  end

  # --- lista de la ayudante: cada caso recibe nack ---

  def test_ayudante_01_sin_idpk_es_malformed
    decision = check(without('idpk'))
    assert_malformed decision
    assert_equal 'falta el campo idpk', decision.detail
  end

  def test_ayudante_02_sin_sender_ni_city_id_es_malformed
    decision = check(without('sender'))
    assert_malformed decision
    assert_equal 'falta el emisor: no trae sender ni cityId', decision.detail
    assert_nil decision.reply_to
  end

  def test_ayudante_03_emisor_no_permitido_es_malformed
    assert_malformed check(sample('transfer', 'sender' => 'otra-central'))
    assert_malformed check(sample('transfer', 'sender' => 'HGW'))
    both = check(sample('transfer', 'cityId' => 'HGW'), 'central')
    assert_malformed both
    assert_nil both.reply_to # lo publico la central: se le responde a ella, no a HGW
    assert_malformed check(sample('bid', 'sender' => 'central'))
  end

  def test_ayudante_04_sin_type_es_malformed
    decision = check(without('type'))
    assert_malformed decision
    assert_equal 'falta el campo type', decision.detail
  end

  def test_ayudante_05_tipo_inexistente_o_retirado_es_unknown_type
    %w[tipo-inventado negotiation-proposal give take demand-statement].each do |type|
      decision = check(sample('transfer', 'type' => type))
      assert_nack decision, 'UNKNOWN_TYPE', 400
      assert_equal "tipo desconocido: #{type}", decision.detail
    end
  end

  def test_ayudante_06_sin_cycle_id_en_un_tipo_que_lo_lleva_es_malformed
    %w[status-statement transfer distance-table trade-recorded imbalance-settlement bid bid-accepted].each do |type|
      decision = check(without('cycleId', sample(type)))
      assert_malformed decision
      assert_equal 'falta el campo cycleId', decision.detail, type
    end
  end

  def test_ayudante_07_sin_timestamp_es_malformed
    decision = check(without('timestamp'))
    assert_malformed decision
    assert_equal 'falta el campo timestamp', decision.detail
  end

  def test_ayudante_08_sin_data_o_data_que_no_es_objeto_es_malformed
    assert_equal 'data debe ser un objeto', check(without('data')).detail
    [nil, 'texto', 5, [1, 2]].each do |data|
      assert_malformed check(sample('transfer', 'data' => data))
      assert_malformed check(sample('bid', 'data' => data))
    end
  end

  def test_ayudante_09_distance_table_sin_distances_es_malformed
    data = sample('distance-table')['data'].except('distances')
    decision = check(sample('distance-table', 'data' => data))
    assert_malformed decision
    assert_equal 'falta el campo data.distances', decision.detail
  end

  def test_ayudante_10_idpk_igual_a_msg_id
    transfer = sample('transfer')
    assert_nack check(transfer.merge('idpk' => transfer['msgId'])), 'IDPK_EQUALS_MSGID', 422
    bid = sample('bid')
    assert_nack check(bid.merge('idpk' => bid['msgId'])), 'IDPK_EQUALS_MSGID', 422
  end

  # --- tipos aceptados ---

  def test_tipos_de_la_central_se_aceptan_con_ack_a_la_central
    %w[status-statement transfer distance-table trade-recorded imbalance-settlement].each do |type|
      decision = check(sample(type))
      assert_accept_with_ack decision
      assert_nil decision.reply_to, type
    end
  end

  # punto 5: los eventos de la wallet traen sender central y no llevan cycleId
  def test_eventos_de_la_wallet_traen_sender_central_y_no_necesitan_cycle_id
    %w[swap-proposed swap-settled swap-cancelled swap-expired swap-rejected].each do |type|
      message = sample(type)
      assert_equal 'central', message['sender']
      refute message.key?('cycleId')
      decision = check(message)
      assert_accept_with_ack decision
      assert_nil decision.reply_to
    end
  end

  def test_evento_de_la_wallet_sin_sender_es_malformed
    assert_malformed check(without('sender', sample('swap-settled')), 'central')
  end

  def test_bid_y_bid_accepted_de_otra_ciudad_se_responden_a_esa_ciudad
    assert_equal 'COR', check(sample('bid')).reply_to
    assert_equal 'HGW', check(sample('bid-accepted')).reply_to
    assert_accept_with_ack check(sample('bid'))
  end

  def test_tipo_de_la_central_enviado_por_una_ciudad_es_malformed
    message = without('sender', sample('transfer')).merge('cityId' => 'HGW')
    decision = check(message)
    assert_malformed decision
    assert_equal 'transfer solo lo puede enviar la central', decision.detail
    assert_equal 'HGW', decision.reply_to
  end

  def test_demand_set_de_la_e1_ya_no_existe
    assert_nack check(sample('transfer', 'type' => 'demand-set')), 'UNKNOWN_TYPE', 400
  end

  def test_tipo_del_mercado_en_la_cola_de_la_ciudad_es_unknown_type
    assert_nack check(sample('offer')), 'UNKNOWN_TYPE', 400
  end

  # punto 8: como receptores, un campo extra no hace rechazar un mensaje de la central
  def test_campos_extra_se_ignoran
    data = sample('transfer')['data'].merge('campoNuevo' => 'x')
    assert_accept_with_ack check(sample('transfer', 'campoNuevo' => 1, 'data' => data))
    assert_accept_with_ack check(sample('swap-settled', 'cycleId' => 'cycle-1'))
  end

  def test_transfer_con_penalty_valida_y_penalty_nula
    data = sample('transfer')['data']
    assert_accept_with_ack check(sample('transfer', 'data' => data.merge('penalty' => { 'amount' => 5,
                                                                                         'forCycleId' => 'cycle-1' })))
    assert_equal 'data.penalty debe ser un objeto', check(sample('transfer', 'data' => data.merge('penalty' => nil))).detail
  end

  # --- cycleId (punto 1 y 2) ---

  def test_distance_table_sin_cycle_id_es_malformed
    decision = check(without('cycleId', sample('distance-table')))
    assert_malformed decision
    assert_equal 'falta el campo cycleId', decision.detail
  end

  def test_cycle_id_null_vacio_o_numero_cuenta_como_ausente
    [nil, '', 9431, ['cycle-1']].each do |cycle_id|
      decision = check(sample('transfer', 'cycleId' => cycle_id))
      assert_malformed decision
      assert_equal 'falta el campo cycleId', decision.detail
    end
  end

  # el schema no le pone maximo: 65 caracteres esta bien formado (el limite de 64 es solo para el eco)
  def test_cycle_id_de_65_caracteres_esta_bien_formado
    assert_accept_with_ack check(sample('bid', 'cycleId' => 'c' * 65))
    assert_accept_with_ack check(sample('transfer', 'cycleId' => 'c' * 200))
  end

  # --- contenido de data ---

  def bid_with(quantity)
    sample('bid', 'data' => { 'offerId' => 'HGW-9431', 'quantity' => quantity })
  end

  def test_bid_con_quantity_que_no_es_entero_es_malformed
    ['7300', 7300.5, 7300.0, nil].each do |quantity|
      decision = check(bid_with(quantity))
      assert_malformed decision
    end
    assert_equal 'data.quantity debe ser un entero', check(bid_with('7300')).detail
  end

  # punto 3: 0 o negativo esta bien formado; la API responde bid-rejected BID_TOO_SMALL
  def test_bid_con_quantity_cero_negativa_o_chica_esta_bien_formado
    [0, -1, 1].each do |quantity|
      assert_accept_with_ack check(bid_with(quantity))
    end
  end

  def test_bid_sin_offer_id_es_malformed
    decision = check(sample('bid', 'data' => { 'quantity' => 7300 }))
    assert_malformed decision
    assert_equal 'falta el campo data.offerId', decision.detail
  end

  def test_bid_accepted_incompleto_es_malformed
    data = sample('bid-accepted')['data']
    assert_equal 'falta el campo data.swapToken',
                 check(sample('bid-accepted', 'data' => data.except('swapToken'))).detail
    assert_equal 'data.target debe ser un UUID', check(sample('bid-accepted', 'data' => data.merge('target' => 'x'))).detail
  end

  def test_status_statement_exige_valid_until_market_y_sellable
    data = sample('status-statement')['data']
    assert_equal 'falta el campo data.validUntil', check(sample('status-statement', 'data' => data.except('validUntil'))).detail
    assert_equal 'falta el campo data.market', check(sample('status-statement', 'data' => data.except('market'))).detail
    energy = data['energy'].merge('sellable' => 10.5)
    assert_equal 'data.energy.sellable debe ser un entero mayor o igual a 0',
                 check(sample('status-statement', 'data' => data.merge('energy' => energy))).detail
  end

  def test_distance_table_exige_codigos_de_ciudad_y_tarifa_punitiva
    data = sample('distance-table')['data']
    route = data['distances'].values.first
    assert_malformed check(sample('distance-table', 'data' => data.merge('distances' => { 'hgw' => route })))
    assert_equal 'falta el campo data.disabledRouteTransportCost',
                 check(sample('distance-table', 'data' => data.except('disabledRouteTransportCost'))).detail
  end

  # --- identidad (user_id) ---

  def test_bid_con_user_id_ajeno_es_identity_mismatch_respondido_a_quien_lo_envio
    decision = check(sample('bid'), 'city.XXX')
    assert_nack decision, 'IDENTITY_MISMATCH', 403
    assert_equal 'XXX', decision.reply_to
  end

  # README v3.0.2: IDENTITY_MISMATCH "si no corresponde o si falta". sin user_id se responde a la
  # ciudad que dice ser, porque es la unica a la que se puede responder
  def test_bid_sin_user_id_es_identity_mismatch_a_la_ciudad_del_city_id
    [nil, 'admin'].each do |user_id|
      decision = check(sample('bid'), user_id)
      assert_nack decision, 'IDENTITY_MISMATCH', 403
      assert_equal 'COR', decision.reply_to
    end
  end

  def test_bid_publicado_por_la_central_se_le_responde_a_la_central
    decision = check(sample('bid'), 'central')
    assert_nack decision, 'IDENTITY_MISMATCH', 403
    assert_nil decision.reply_to
  end

  # punto 4: la central siempre publica con user_id central. si no, no la publico ella
  def test_mensaje_de_la_central_sin_user_id_central_se_descarta_sin_responder
    [nil, 'city.XXX', 'admin', 'Central'].each do |user_id|
      %w[transfer swap-settled ack error].each do |type|
        decision = check(sample(type), user_id)
        assert_discard decision
        assert_equal 'IDENTITY_MISMATCH', decision.reason
      end
    end
  end

  def test_mensaje_de_la_central_con_user_id_central_se_acepta
    assert_accept_with_ack check(sample('transfer'), 'central')
  end

  # punto 7
  def test_city_id_fuera_del_patron_es_malformed
    %w[hgw city.HGW HG HGWX].each do |city_id|
      decision = check(sample('bid', 'cityId' => city_id), 'city.COR')
      assert_malformed decision
      assert_equal 'COR', decision.reply_to
    end
  end

  def test_city_id_fuera_del_patron_sin_user_id_se_descarta
    assert_discard check(sample('bid', 'cityId' => 'hgw'), nil)
  end

  def test_mensaje_mal_formado_de_una_ciudad_se_responde_a_la_ciudad_del_user_id
    decision = check(without('idpk', sample('bid')), 'city.XXX')
    assert_malformed decision
    assert_equal 'XXX', decision.reply_to
  end

  def test_envelope_exige_uuid_y_timestamp_con_zona
    assert_equal 'idpk debe ser un UUID', check(sample('transfer', 'idpk' => 'abc')).detail
    assert_equal 'msgId debe ser un UUID', check(sample('transfer', 'msgId' => 'abc')).detail
    assert_equal 'timestamp debe ser una fecha ISO 8601 con zona horaria',
                 check(sample('transfer', 'timestamp' => '2026-10-20T14:05:41')).detail
    assert_malformed check(sample('transfer', 'timestamp' => 'ayer'))
    assert_accept_with_ack check(sample('transfer', 'timestamp' => '2026-10-20T11:05:41-03:00'))
  end

  # --- tipos que nunca se responden ---

  def test_ack_nack_error_y_bid_rejected_se_aceptan_sin_responder
    %w[ack nack error bid-rejected].each do |type|
      assert_accept_without_reply check(sample(type))
    end
  end

  def test_bid_rejected_mal_formado_se_descarta_sin_responder
    message = sample('bid-rejected')
    [
      without('cycleId', message),
      without('reason', message),
      message.merge('code' => '409'),
      message.merge('data' => message['data'].except('available')),
      message.merge('idpk' => message['msgId'])
    ].each do |bad|
      assert_discard check(bad)
    end
    assert_discard check(message, 'city.XXX')
  end

  def test_bid_rejected_bid_too_small_es_valido
    message = sample('bid-rejected', 'reason' => 'BID_TOO_SMALL', 'code' => 422)
    assert_accept_without_reply check(message.merge('data' => message['data'].except('available')))
  end

  def test_nack_invalido_se_descarta_sin_responder
    assert_discard check(without('idpk', sample('nack')))
  end

  # --- cola del mercado ---

  def check_market(message, user_id = Samples.user_for(message))
    check(message, user_id, queue: :market)
  end

  # punto 6
  def test_mercado_market_closed_llega_sin_user_id_y_se_acepta
    message = sample('market-closed')
    assert_equal({}, message['data'])
    assert_accept_without_reply check_market(message, nil)
  end

  def test_mercado_market_closed_publicado_por_una_ciudad_se_descarta
    assert_discard check_market(sample('market-closed'), 'city.XXX')
  end

  def test_mercado_ofertas_validas_se_aceptan_sin_responder
    %w[offer offer-updated offer-withdrawn].each do |type|
      assert_accept_without_reply check_market(sample(type))
    end
  end

  def test_mercado_oferta_sin_user_id_o_con_uno_ajeno_se_descarta
    [nil, 'city.XXX', 'central'].each do |user_id|
      decision = check_market(sample('offer'), user_id)
      assert_discard decision
      assert_equal 'IDENTITY_MISMATCH', decision.reason
    end
  end

  def test_mercado_nada_recibe_nack_todo_lo_invalido_se_descarta
    offer = sample('offer')
    [
      without('idpk', offer),
      offer.merge('idpk' => offer['msgId']),
      offer.merge('data' => 'texto'),
      without('cycleId', offer),
      sample('bid'),
      sample('transfer'),
      offer.merge('type' => 'tipo-inventado')
    ].each do |message|
      assert_discard check_market(message)
    end
  end

  # --- lo de la E1 que se mantiene ---

  def test_texto_que_no_es_json_se_descarta
    assert_discard MessageValidator.check('esto no es json')
  end

  def test_json_que_no_es_un_objeto_se_descarta
    assert_discard MessageValidator.check('[1, 2, 3]')
  end

  def test_sin_msg_id_se_descarta
    assert_discard check(without('msgId'))
    assert_discard check(without('msgId', sample('bid')))
  end

  def test_byte_invalido_dentro_de_un_texto_se_descarta
    body = "{\"msgId\":\"a\xFF\"}"
    assert_discard MessageValidator.check(body)
    assert_discard MessageValidator.check(body.b)
  end

  def test_mensaje_valido_que_llega_como_bytes_se_acepta
    body = JSON.generate(sample('transfer', 'nota' => 'ñandú')).b
    assert_equal :accept, MessageValidator.check(body, 'central').action
  end

  ALLOWED_NACKS = {
    'MALFORMED_MESSAGE' => 422, 'UNKNOWN_TYPE' => 400, 'IDPK_EQUALS_MSGID' => 422, 'IDENTITY_MISMATCH' => 403
  }.freeze

  def test_cada_nack_usa_un_reason_y_code_del_enunciado
    transfer = sample('transfer')
    messages = [
      [transfer.merge('idpk' => transfer['msgId'])], [transfer.merge('type' => 'give')], [without('idpk')],
      [without('timestamp')], [without('cycleId')], [sample('bid'), 'city.XXX'], [sample('bid'), nil]
    ]
    messages.each do |message, *user_id|
      decision = check(message, *user_id)
      assert_equal :nack, decision.action
      assert_equal ALLOWED_NACKS.fetch(decision.reason), decision.code
    end
  end

  def test_ninguna_entrada_hace_que_check_lance_una_excepcion
    entradas = [
      nil, '', ' ', 'null', '5', '"texto"', '{}', '{', "\x00", "\xFF\xFE".b, 42, :simbolo, [], {},
      '[' * 500, '{"msgId":{"a":1}}', '{"msgId":"a","type":["ack"]}', '{"msgId":"a","cityId":{"x":1}}',
      JSON.generate(sample('transfer', 'timestamp' => '2026-99-99T99:99:99Z')),
      JSON.generate(sample('transfer', 'timestamp' => 12)),
      JSON.generate(sample('distance-table', 'data' => { 'distances' => [1] })),
      JSON.generate(sample('distance-table', 'data' => { 'distances' => { 'AAA' => nil } })),
      JSON.generate(sample('swap-settled', 'data' => { 'give' => 5, 'balancesAfter' => [] })),
      JSON.generate(sample('bid-rejected', 'reason' => ['x'], 'data' => 5)),
      JSON.generate(sample('bid', 'cityId' => 5)),
      JSON.generate(sample('bid', 'cycleId' => { 'a' => 1 }))
    ]
    entradas.each do |entrada|
      [nil, 'city.HGW', 'central', 5, ''].each do |user_id|
        %i[city market].each do |queue|
          decision = MessageValidator.check(entrada, user_id, queue: queue)
          assert_includes %i[discard nack accept], decision.action
        end
      end
    end
  end
end
