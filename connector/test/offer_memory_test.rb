require 'minitest/autorun'
require 'time'
require_relative '../lib/offer_memory'

# correr desde /connector: ruby test/offer_memory_test.rb
class OfferMemoryTest < Minitest::Test
  LAST_OFFER_AT = Time.iso8601('2026-11-06T15:00:00Z')
  BEFORE = LAST_OFFER_AT - 60

  def setup
    @memory = OfferMemory.new
    @memory.status_received(status('cycle-7'))
  end

  def status(cycle_id, last_offer_at = LAST_OFFER_AT.iso8601)
    { 'type' => 'status-statement', 'cycleId' => cycle_id, 'data' => { 'market' => { 'lastOfferAt' => last_offer_at } } }
  end

  def offer(type = 'offer', cycle_id: 'cycle-7', offer_id: 'TK3-cycle-7')
    { 'type' => type, 'idpk' => "idpk-#{type}", 'cycleId' => cycle_id, 'data' => { 'offerId' => offer_id } }
  end

  def publish(message)
    @memory.offer_published(message, 'market', 'market.offer.TK3')
  end

  def test_without_an_offer_there_is_nothing_to_republish
    assert_nil @memory.offer_to_republish(BEFORE)
  end

  def test_remembers_the_last_offer_and_where_it_went
    publish(offer)
    publish(offer('offer-updated'))

    remembered = @memory.offer_to_republish(BEFORE)
    assert_equal 'idpk-offer-updated', remembered.message['idpk']
    assert_equal ['market', 'market.offer.TK3'], [remembered.exchange, remembered.routing_key]
  end

  def test_forgets_it_when_it_is_withdrawn
    publish(offer)
    publish(offer('offer-withdrawn'))

    assert_nil @memory.offer_to_republish(BEFORE)
  end

  def test_withdrawing_another_offer_does_not_forget_ours
    publish(offer)
    publish(offer('offer-withdrawn', offer_id: 'TK3-cycle-6'))

    refute_nil @memory.offer_to_republish(BEFORE)
  end

  def test_other_types_do_not_change_the_offer
    publish(offer)
    publish({ 'type' => 'bid', 'cycleId' => 'cycle-7', 'data' => {} })

    assert_equal 'idpk-offer', @memory.offer_to_republish(BEFORE).message['idpk']
  end

  def test_an_offer_from_a_past_cycle_is_not_returned
    publish(offer)
    @memory.status_received(status('cycle-8'))

    assert_nil @memory.offer_to_republish(BEFORE)
  end

  def test_not_returned_from_last_offer_at_on
    publish(offer)

    assert_nil @memory.offer_to_republish(LAST_OFFER_AT)
    assert_nil @memory.offer_to_republish(LAST_OFFER_AT + 1)
  end

  def test_without_a_status_statement_nothing_is_returned
    memory = OfferMemory.new
    memory.offer_published(offer, 'market', 'market.offer.TK3')

    assert_nil memory.offer_to_republish(BEFORE)
  end

  def test_a_bad_last_offer_at_means_nothing_is_returned
    publish(offer)
    @memory.status_received(status('cycle-7', 'mañana'))

    assert_nil @memory.offer_to_republish(BEFORE)
  end

  def test_only_status_statements_change_the_cycle
    publish(offer)
    @memory.status_received({ 'type' => 'transfer', 'cycleId' => 'cycle-8', 'data' => {} })

    refute_nil @memory.offer_to_republish(BEFORE)
  end
end
