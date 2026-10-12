# frozen_string_literal: true

module Xeroizer
  module Record
    # Billable expenses: links a line item on a purchase (ACCPAY invoice or SPEND
    # bank transaction) to a customer and, once billed, to a line item on an
    # ACCREC invoice. Xero has no bulk update for this endpoint, so updates POST
    # one record to LinkedTransactions/{LinkedTransactionID}.
    class LinkedTransactionModel < BaseModel
      set_permissions :read, :write, :update
      set_xml_root_name 'LinkedTransactions'
      set_get_options :SourceTransactionID, :ContactID, :TargetTransactionID, :status
    end

    class LinkedTransaction < Base
      set_primary_key :linked_transaction_id

      guid          :linked_transaction_id
      guid          :source_transaction_id
      guid          :source_line_item_id
      guid          :contact_id
      guid          :target_transaction_id
      guid          :target_line_item_id
      string        :status, read_only: true
      string        :type, read_only: true
      string        :source_transaction_type_code, read_only: true
      datetime_utc  :updated_date_utc, api_name: 'UpdatedDateUTC', read_only: true

      validates_presence_of :source_transaction_id, :source_line_item_id, allow_blanks: false

      protected

      def update(options = {})
        raise RecordKeyMustBeDefined, self.class.possible_primary_keys if id.nil?

        request = to_xml
        log "[UPDATE SENT] (#{__FILE__}:#{__LINE__}) \r\n#{request}"

        application = parent.application
        response = application.http_post(application.client, "#{parent.url}/#{CGI.escape(id)}", request, options)

        log "[UPDATE RECEIVED] (#{__FILE__}:#{__LINE__}) \r\n#{response}"
        parse_save_response(response)
      end
    end
  end
end
