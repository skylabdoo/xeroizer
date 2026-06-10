# frozen_string_literal: true

module Xeroizer
  module Record
    class ContactGroupModel < BaseModel
      set_permissions :read
    end

    class ContactGroup < Base
      guid :contact_group_id
      string :name
      string :status

      set_primary_key :contact_group_id
      list_contains_summary_only true
      has_many :contacts, list_complete: true

      # Adding Contact uses different API endpoint
      # https://developer.xero.com/documentation/api/contactgroups#PUT
      def add_contact(contact)
        @contacts ||= []
        @contacts <<  contact
      end

      def delete
        'DELETED'
      end

      def name=(value)
        @modified = true unless @attributes[:name].nil? or @attributes[:name] == value
        @attributes[:name] = value
      end

      def status=(value)
        @modified = true unless @attributes[:status].nil? or @attributes[:status] == value
        @attributes[:status] = value
      end

      # @param [Hash] options forwarded to the record create/update.
      # @option options [String] :idempotency_key (nil) sets the +Idempotency-Key+
      #   header. The membership PUT is a separate request, so it gets a derived
      #   <tt>"#{key}-contacts"</tt> key, keeping the whole save idempotent
      #   under one caller key.
      def save!(options = {})
        # Derive the membership key before the primary save, so a bad key fails up front.
        membership_key = @contacts ? derived_idempotency_key(options, 'contacts') : nil
        super if new_record? or @modified
        @modified = false
        return unless @contacts

        req = cg_xml
        app = parent.application
        extra_params = Http.with_idempotency_key({}, membership_key)
        res = app.http_put(app.client, "#{parent.url}/#{CGI.escape(id)}/Contacts", req, extra_params)
        parse_save_response(res)
      end

      def cg_xml
        b = Builder::XmlMarkup.new(indent: 2)
        b.tag!('Contacts') do
          @contacts.each do |c|
            b.tag!('Contact') do
              b.tag!('ContactID', c.id)
            end
          end
        end
      end
    end
  end
end
