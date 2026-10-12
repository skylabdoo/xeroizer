# frozen_string_literal: true

require 'unit_test_helper'

class LinkedTransactionTest < Minitest::Test
  include TestHelper

  URL = 'https://api.xero.com/api.xro/2.0/LinkedTransactions'

  BILLED_ID     = '2b921ac0-1ed9-4a61-bd67-706180f1bd94'
  UNBILLED_ID   = 'dc3c18e6-ab39-4d0e-8283-0609efa36145'
  SOURCE_ID     = '0cfcc9f7-9166-4dae-9b7c-7d0f25663886'
  SOURCE_LINE   = 'da115c3b-41e5-4204-a7a3-082323197f9f'
  CONTACT_ID    = '73d15ee0-27db-4352-ac8d-28463a2110f4'
  TARGET_ID     = '2e926f7b-022c-44d3-8a9a-a5201dd37b61'
  TARGET_LINE   = '43c944b5-1556-42d6-aa35-b3a60f6c0a49'

  def setup
    @client = Xeroizer::OAuth2Application.new(CLIENT_ID, CLIENT_SECRET)
  end

  should 'have LinkedTransactionID as the primary key' do
    assert_equal :linked_transaction_id, Xeroizer::Record::LinkedTransaction.primary_key_name
  end

  context 'parsing a GET response' do
    setup do
      mock_api('LinkedTransactions')
      @linked_transactions = @client.LinkedTransaction.all
    end

    should 'read every field of a billed linked transaction' do
      billed = @linked_transactions.first
      assert_equal BILLED_ID, billed.linked_transaction_id
      assert_equal BILLED_ID, billed.id
      assert_equal '057df639-6632-4995-b0ac-00152e1c5092', billed.source_transaction_id
      assert_equal 'aa605236-49cc-4cf7-8c43-161def9bbf68', billed.source_line_item_id
      assert_equal 'a94c0f29-8924-4b05-b0e6-585ea1982faa', billed.contact_id
      assert_equal '147f3680-1b41-48ee-8c7f-61a656bbf49a', billed.target_transaction_id
      assert_equal '14f06cf1-e2af-4825-8476-bb79f5ba503e', billed.target_line_item_id
      assert_equal 'BILLED', billed.status
      assert_equal 'BILLABLEEXPENSE', billed.type
      assert_equal 'SPEND', billed.source_transaction_type_code
      assert_equal Time.utc(2015, 9, 9, 22, 13, 28), billed.updated_date_utc
    end

    should 'leave contact and target fields nil on an unassigned linked transaction' do
      unbilled = @linked_transactions.last
      assert_equal UNBILLED_ID, unbilled.id
      assert_nil unbilled.contact_id
      assert_nil unbilled.target_transaction_id
      assert_nil unbilled.target_line_item_id
      assert_equal 'DRAFT', unbilled.status
      assert_equal 'ACCPAY', unbilled.source_transaction_type_code
    end

    should 'find a single linked transaction by id' do
      found = @client.LinkedTransaction.find(UNBILLED_ID)
      assert_equal UNBILLED_ID, found.id
      assert_equal '0465c7b5-69b8-4e55-8c32-af73eab9afba', found.source_transaction_id
    end
  end

  context 'creating' do
    should 'PUT the source, contact and target IDs' do
      @client.expects(:http_put).with do |_client, url, body, _params|
        url == URL && body == expected_create_body
      end.returns(create_response)

      linked_transaction = @client.LinkedTransaction.build(
        source_transaction_id: SOURCE_ID,
        source_line_item_id: SOURCE_LINE,
        contact_id: CONTACT_ID,
        target_transaction_id: TARGET_ID,
        target_line_item_id: TARGET_LINE
      )
      assert linked_transaction.save, linked_transaction.errors.inspect

      assert_equal 'c83947a9-5f57-47c4-bdb1-b77862207382', linked_transaction.id
      assert_equal 'BILLED', linked_transaction.status
      assert_equal 'ACCPAY', linked_transaction.source_transaction_type_code
    end

    should 'allow a create with only the source IDs' do
      @client.expects(:http_put).with do |_client, url, body, _params|
        url == URL && body == <<~XML
          <LinkedTransaction>
            <SourceTransactionID>#{SOURCE_ID}</SourceTransactionID>
            <SourceLineItemID>#{SOURCE_LINE}</SourceLineItemID>
          </LinkedTransaction>
        XML
      end.returns(create_response)

      linked_transaction = @client.LinkedTransaction.build(
        source_transaction_id: SOURCE_ID, source_line_item_id: SOURCE_LINE
      )
      assert linked_transaction.save, linked_transaction.errors.inspect
    end

    should 'never send the read-only Status, Type, SourceTransactionTypeCode or UpdatedDateUTC' do
      mock_api('LinkedTransactions')
      xml = @client.LinkedTransaction.all.first.to_xml

      assert_match(/<LinkedTransactionID>/, xml)
      assert_match(/<SourceTransactionID>/, xml)
      refute_match(/<Status>/, xml)
      refute_match(/<Type>/, xml)
      refute_match(/<SourceTransactionTypeCode>/, xml)
      refute_match(/<UpdatedDateUTC>/, xml)
    end

    should 'require SourceTransactionID and SourceLineItemID' do
      linked_transaction = @client.LinkedTransaction.build(contact_id: CONTACT_ID)

      refute linked_transaction.valid?
      refute_empty linked_transaction.errors_for(:source_transaction_id)
      refute_empty linked_transaction.errors_for(:source_line_item_id)
    end

    should 'not send anything for an invalid record' do
      @client.expects(:http_put).never
      linked_transaction = @client.LinkedTransaction.build(source_transaction_id: SOURCE_ID)
      refute linked_transaction.save
    end
  end

  context 'updating' do
    setup do
      mock_api('LinkedTransactions')
      @unbilled = @client.LinkedTransaction.all.last
    end

    should 'POST to LinkedTransactions/{LinkedTransactionID} with the record id in the body' do
      @client.expects(:http_post).with do |_client, url, body, _params|
        url == "#{URL}/#{UNBILLED_ID}" && body == expected_update_body
      end.returns(update_response)

      @unbilled.contact_id = CONTACT_ID
      @unbilled.target_transaction_id = TARGET_ID
      @unbilled.target_line_item_id = TARGET_LINE
      assert @unbilled.save, @unbilled.errors.inspect

      assert_equal UNBILLED_ID, @unbilled.id
      assert_equal 'BILLED', @unbilled.status
      assert_equal TARGET_ID, @unbilled.target_transaction_id
    end
  end

  context 'GET filters' do
    should 'pass SourceTransactionID, ContactID, Status, TargetTransactionID and page as query parameters' do
      expected_params = {
        SourceTransactionID: SOURCE_ID,
        ContactID: CONTACT_ID,
        Status: 'APPROVED',
        TargetTransactionID: TARGET_ID,
        page: 2
      }
      @client.expects(:http_get).with do |_client, url, params|
        url == URL && params == expected_params
      end.returns(get_record_xml(:linked_transactions))

      @client.LinkedTransaction.all(
        SourceTransactionID: SOURCE_ID,
        ContactID: CONTACT_ID,
        status: 'APPROVED',
        TargetTransactionID: TARGET_ID,
        page: 2
      )
    end
  end

  private

  def expected_create_body
    <<~XML
      <LinkedTransaction>
        <SourceTransactionID>#{SOURCE_ID}</SourceTransactionID>
        <SourceLineItemID>#{SOURCE_LINE}</SourceLineItemID>
        <ContactID>#{CONTACT_ID}</ContactID>
        <TargetTransactionID>#{TARGET_ID}</TargetTransactionID>
        <TargetLineItemID>#{TARGET_LINE}</TargetLineItemID>
      </LinkedTransaction>
    XML
  end

  # Attribute order follows the GET response the record was parsed from.
  def expected_update_body
    <<~XML
      <LinkedTransaction>
        <LinkedTransactionID>#{UNBILLED_ID}</LinkedTransactionID>
        <SourceTransactionID>0465c7b5-69b8-4e55-8c32-af73eab9afba</SourceTransactionID>
        <SourceLineItemID>c92bf129-5da1-401c-8cf5-1508e92ee829</SourceLineItemID>
        <ContactID>#{CONTACT_ID}</ContactID>
        <TargetTransactionID>#{TARGET_ID}</TargetTransactionID>
        <TargetLineItemID>#{TARGET_LINE}</TargetLineItemID>
      </LinkedTransaction>
    XML
  end

  def create_response
    <<~XML
      <Response xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <Id>3d6f1a2b-8c4e-4f5a-9b7d-6e2c1a0f9d8e</Id>
        <Status>OK</Status>
        <ProviderName>Xero API Previewer</ProviderName>
        <DateTimeUTC>2015-09-10T01:20:11.2203612Z</DateTimeUTC>
        <LinkedTransactions>
          <LinkedTransaction>
            <LinkedTransactionID>c83947a9-5f57-47c4-bdb1-b77862207382</LinkedTransactionID>
            <SourceTransactionID>#{SOURCE_ID}</SourceTransactionID>
            <SourceLineItemID>#{SOURCE_LINE}</SourceLineItemID>
            <ContactID>#{CONTACT_ID}</ContactID>
            <TargetTransactionID>#{TARGET_ID}</TargetTransactionID>
            <TargetLineItemID>#{TARGET_LINE}</TargetLineItemID>
            <Status>BILLED</Status>
            <Type>BILLABLEEXPENSE</Type>
            <UpdatedDateUTC>2015-09-10T01:20:11</UpdatedDateUTC>
            <SourceTransactionTypeCode>ACCPAY</SourceTransactionTypeCode>
          </LinkedTransaction>
        </LinkedTransactions>
      </Response>
    XML
  end

  def update_response
    <<~XML
      <Response xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
        <Id>7a9b8c7d-6e5f-4a3b-8c2d-1e0f9a8b7c6d</Id>
        <Status>OK</Status>
        <ProviderName>Xero API Previewer</ProviderName>
        <DateTimeUTC>2015-09-10T01:25:40.9012345Z</DateTimeUTC>
        <LinkedTransactions>
          <LinkedTransaction>
            <LinkedTransactionID>#{UNBILLED_ID}</LinkedTransactionID>
            <SourceTransactionID>0465c7b5-69b8-4e55-8c32-af73eab9afba</SourceTransactionID>
            <SourceLineItemID>c92bf129-5da1-401c-8cf5-1508e92ee829</SourceLineItemID>
            <ContactID>#{CONTACT_ID}</ContactID>
            <TargetTransactionID>#{TARGET_ID}</TargetTransactionID>
            <TargetLineItemID>#{TARGET_LINE}</TargetLineItemID>
            <Status>BILLED</Status>
            <Type>BILLABLEEXPENSE</Type>
            <UpdatedDateUTC>2015-09-10T01:25:40</UpdatedDateUTC>
            <SourceTransactionTypeCode>ACCPAY</SourceTransactionTypeCode>
          </LinkedTransaction>
        </LinkedTransactions>
      </Response>
    XML
  end
end
