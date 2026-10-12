# frozen_string_literal: true

require 'unit_test_helper'

module Xeroizer
  module Record
    class ParseParamTestModel < BaseModel
    end

    class ParseParamTest < Base
      set_primary_key :primary_key_id

      guid      :primary_key_id
      string    :string1
      boolean   :boolean1
      integer   :integer1
      decimal   :decimal1
      date      :date1
      datetime  :datetime1
    end
  end
end

class ParseParamsTest < Minitest::Test
  include TestHelper

  def setup
    @client = Xeroizer::OAuth2Application.new(CLIENT_ID, CLIENT_SECRET)
    @model = Xeroizer::Record::ParseParamTestModel.new(@client, 'ParseParamTest')
  end

  context 'should return valid and filtered params' do
    should 'filter unsupported keys' do
      params = @model.send(:parse_params, {
                             should_be_filtered_out: 'should be filtered',
                             modified_since: Date.parse('2010-01-05'),
                             include_archived: true,
                             order: :order,
                             where: 'where string',
                             IDs: %w[29ed7958-0466-486d-bf57-3fd966ea37d7 d561892a-9023-498c-a28d-c626ed3940d8],
                             InvoiceNumbers: 'INV-0034,INV-0035,INV-0036,INV-0037',
                             ContactIDs: 'b919a496-1a1c-4fc6-b6ef-8c561e0dd8c2,8289cca4-90a9-466b-95f3-f0adf351b2ac',
                             Statuses: ['DRAFT', nil, 'SUBMITTED'],
                             SourceTransactionID: '0cfcc9f7-9166-4dae-9b7c-7d0f25663886',
                             ContactID: '73d15ee0-27db-4352-ac8d-28463a2110f4',
                             TargetTransactionID: '2e926f7b-022c-44d3-8a9a-a5201dd37b61',
                             status: 'APPROVED',
                             offset: 100,
                             page: 2
                           })

      params.assert_valid_keys(:ModifiedAfter, :includeArchived, :order, :where,
                               :IDs, :InvoiceNumbers, :ContactIDs, :Statuses,
                               :SourceTransactionID, :ContactID, :TargetTransactionID, :Status,
                               :offset, :page)
      assert_equal(params[:IDs], '29ed7958-0466-486d-bf57-3fd966ea37d7,d561892a-9023-498c-a28d-c626ed3940d8')
      assert_equal(params[:InvoiceNumbers], 'INV-0034,INV-0035,INV-0036,INV-0037')
      assert_equal(params[:ContactIDs], 'b919a496-1a1c-4fc6-b6ef-8c561e0dd8c2,8289cca4-90a9-466b-95f3-f0adf351b2ac')
      assert_equal(params[:Statuses], 'DRAFT,,SUBMITTED')
      assert_equal(params[:SourceTransactionID], '0cfcc9f7-9166-4dae-9b7c-7d0f25663886')
      assert_equal(params[:ContactID], '73d15ee0-27db-4352-ac8d-28463a2110f4')
      assert_equal(params[:TargetTransactionID], '2e926f7b-022c-44d3-8a9a-a5201dd37b61')
      assert_equal(params[:Status], 'APPROVED')
    end
  end
end
