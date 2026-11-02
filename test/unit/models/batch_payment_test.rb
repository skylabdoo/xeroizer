# frozen_string_literal: true

require 'unit_test_helper'

class BatchPaymentTest < Minitest::Test
  include TestHelper

  def setup
    @client = Xeroizer::OAuth2Application.new(CLIENT_ID, CLIENT_SECRET)
  end

  context 'the text fields Xero takes in NZ' do
    setup do
      @batch = @client.BatchPayment.build(
        reference: 'BPNZ170726',
        particulars: 'Part 1/2',
        code: 'CREDITORS',
        payments: [{ amount: 1, reference: 'REF', particulars: 'PART', code: 'CODE' }]
      )
      @xml = Nokogiri::XML(@batch.to_xml)
    end

    should 'be written on the batch' do
      assert_equal 'BPNZ170726', @xml.at_xpath('/BatchPayment/Reference').text
      assert_equal 'Part 1/2', @xml.at_xpath('/BatchPayment/Particulars').text
      assert_equal 'CREDITORS', @xml.at_xpath('/BatchPayment/Code').text
    end

    should 'be written on each payment' do
      payment = @xml.at_xpath('/BatchPayment/Payments/Payment')

      assert_equal 'REF', payment.at_xpath('Reference').text
      assert_equal 'PART', payment.at_xpath('Particulars').text
      assert_equal 'CODE', payment.at_xpath('Code').text
    end

    should 'be left out when not set' do
      xml = Nokogiri::XML(@client.BatchPayment.build(details: 'RUN 7').to_xml)

      assert_nil xml.at_xpath('/BatchPayment/Particulars')
      assert_nil xml.at_xpath('/BatchPayment/Code')
    end
  end
end
