# frozen_string_literal: true

module Xeroizer
  module Record
    class AttachmentModel < BaseModel
      module Extensions
        def attach_data(id, filename, data, content_type = 'application/octet-stream', options = {})
          application.Attachment.attach_data(url, id, filename, data, content_type, options)
        end

        def attach_file(id, filename, path, content_type = 'application/octet-stream', options = {})
          application.Attachment.attach_file(url, id, filename, path, content_type, options)
        end

        def attachments(id)
          application.Attachment.attachments_for(url, id)
        end
      end

      set_permissions :read

      # Upload attachment +data+ to a record and return the created Attachment.
      #
      # @param [String] url the parent record's attachments collection URL.
      # @param [String] id the parent record's ID.
      # @param [String] filename name to store the attachment under.
      # @param [String] data the raw attachment bytes.
      # @param [String] content_type the data's MIME type.
      # @param [Hash] options
      # @option options [Boolean] :include_online (false) sets Xero's IncludeOnline flag.
      # @option options [String] :idempotency_key (nil) sets the +Idempotency-Key+ header.
      def attach_data(url, id, filename, data, content_type, options = {})
        # content_type is required here, so a Hash never originates at this method — it
        # arrives from the public Extensions helpers, where content_type IS optional:
        # omitting it makes a trailing options hash (or a collapsed idempotency_key:)
        # bind to this slot. All four such helpers funnel through this worker, so the
        # arg is normalized once here at the chokepoint rather than in each helper.
        if content_type.is_a?(Hash)
          options = content_type
          content_type = 'application/octet-stream'
        end
        options = { include_online: false }.merge(options)

        extra_params = {
          :raw_body => true,
          :content_type => content_type,
          'IncludeOnline' => options[:include_online]
        }
        extra_params = Http.with_idempotency_key(extra_params, options[:idempotency_key])

        response_xml = @application.http_put(@application.client,
                                             "#{url}/#{CGI.escape(id)}/Attachments/#{CGI.escape(filename)}",
                                             data,
                                             extra_params)
        response = parse_response(response_xml)
        if (response_items = response.response_items) && response_items.size > 0
          response_items.size == 1 ? response_items.first : response_items
        else
          response
        end
      end

      def attach_file(url, id, filename, path, content_type, options = {})
        attach_data(url, id, filename, File.read(path), content_type, options)
      end

      def attachments_for(url, id)
        response_xml = @application.http_get(@application.client,
                                             "#{url}/#{CGI.escape(id)}/Attachments")

        response = parse_response(response_xml)
        if (response_items = response.response_items) && response_items.size > 0
          response_items
        else
          []
        end
      end
    end

    class Attachment < Base
      module Extensions
        def attach_file(filename, path, content_type = 'application/octet-stream', options = {})
          parent.attach_file(id, filename, path, content_type, options)
        end

        def attach_data(filename, data, content_type = 'application/octet-stream', options = {})
          parent.attach_data(id, filename, data, content_type, options)
        end

        def attachments
          parent.attachments(id)
        end
      end

      set_primary_key :attachment_id

      guid    :attachment_id
      string  :file_name
      string  :url
      string  :mime_type
      integer :content_length

      # Retrieve the attachment data.
      # @param [String] filename optional filename to store the attachment in instead of returning the data.
      def get(filename = nil)
        data = parent.application.http_get(parent.application.client, url)
        if filename
          File.binwrite(filename, data)
          nil
        else
          data
        end
      end
    end
  end
end
