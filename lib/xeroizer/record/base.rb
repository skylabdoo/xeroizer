# frozen_string_literal: true

require 'xeroizer/record/model_definition_helper'
require 'xeroizer/record/record_association_helper'
require 'xeroizer/record/validation_helper'
require 'xeroizer/record/xml_helper'
require 'xeroizer/logging'

module Xeroizer
  module Record
    class Base
      include ClassLevelInheritableAttributes
      class_inheritable_attributes :fields, :possible_primary_keys, :primary_key_name, :summary_only, :validators

      attr_reader :attributes
      attr_reader :parent
      attr_reader :model
      attr_accessor :errors
      attr_accessor :complete_record_downloaded
      attr_accessor :paged_record_downloaded

      include ModelDefinitionHelper
      include RecordAssociationHelper
      include ValidationHelper
      include XmlHelper

      class << self
        # Build a record with attributes set to the value of attributes.
        def build(attributes, parent)
          record = new(parent)
          attributes.each do |key, value|
            record.send("#{record.resolve_attribute_key(key)}=", value)
          end
          record
        end
      end

      public

      def initialize(parent)
        @parent = parent
        @model = new_model_class(self.class.name.demodulize)
        @attributes = {}
      end

      def new_model_class(model_name)
        Xeroizer::Record.const_get("#{model_name}Model".to_sym).new(parent.try(:application), model_name.to_s)
      end

      def [](attribute)
        send(attribute)
      end

      def []=(attribute, value)
        parent.mark_dirty(self) if parent
        send("#{attribute}=".to_sym, value)
      end

      def non_calculated_attributes
        attributes.except(:parent).map do |k, v|
          [k, if v.is_a?(Array)
                v.map(&:to_h)
              else
                (v.respond_to?(:to_h) ? v.to_h : v)
              end]
        end.to_h
      end

      def attributes=(new_attributes)
        return unless new_attributes.is_a?(Hash)

        parent.mark_dirty(self) if parent
        new_attributes.each do |key, value|
          send("#{resolve_attribute_key(key)}=", value)
        end
      end

      def resolve_attribute_key(key)
        field = self.class.fields[key]
        respond_to?("#{key}=") || field.nil? ? key : field[:internal_name]
      end

      def update_attributes(attributes)
        self.attributes = attributes
        save
      end

      def new_record?
        id.nil?
      end

      # Check to see if the complete record is downloaded.
      def complete_record_downloaded?
        if !!self.class.list_contains_summary_only?
          !!complete_record_downloaded
        else
          true
        end
      end

      def paged_record_downloaded?
        !!paged_record_downloaded
      end

      # Downloads the complete record if we only have a summary of the record.
      def download_complete_record!
        record = parent.find(id)
        @attributes = record.attributes if record
        @complete_record_downloaded = true
        parent.mark_clean(self)
        self
      end

      # @param [Hash] options request options forwarded to the HTTP layer.
      # @option options [String] :idempotency_key (nil) sets the +Idempotency-Key+ header.
      # @return [Boolean] true on success, false on a save failure (XeroizerError).
      # @raise [ArgumentError] if :idempotency_key is invalid (callable/non-String/blank).
      def save(options = {})
        save!(options)
        true
      rescue XeroizerError => e
        log "[ERROR SAVING] (#{__FILE__}:#{__LINE__}) - #{e.message}"
        false
      end

      def save!(options = {})
        raise RecordInvalid unless valid?

        if new_record?
          create(options)
        else
          update(options)
        end

        saved!
      end

      def saved!
        @complete_record_downloaded = true
        parent.mark_clean(self)
        true
      end

      def to_json(*args)
        to_h.to_json(*args)
      end

      # Deprecated
      def as_json(_options = {})
        to_h.to_json
      end

      def to_h
        attrs = attributes.except(:parent).map do |k, v|
          [k, if v.is_a?(Array)
                v.map(&:to_h)
              else
                (v.respond_to?(:to_h) ? v.to_h : v)
              end]
        end
        attrs.to_h
      end

      def inspect
        attribute_string = attributes.collect do |attr, value|
          "#{attr.inspect}: #{value.inspect}"
        end.join(', ')
        "#<#{self.class} #{attribute_string}>"
      end

    protected

      # Attempt to create a new record.
      def create(options = {})
        request = to_xml
        log "[CREATE SENT] (#{__FILE__}:#{__LINE__}) #{request}"

        response = parent.send(parent.create_method, request, options)

        log "[CREATE RECEIVED] (#{__FILE__}:#{__LINE__}) #{response}"

        parse_save_response(response)
      end

      # Attempt to update an existing record.
      def update(options = {})
        if self.class.possible_primary_keys && self.class.possible_primary_keys.all? { |possible_key| self[possible_key].nil? }
          raise RecordKeyMustBeDefined, self.class.possible_primary_keys
        end

        request = to_xml

        log "[UPDATE SENT] (#{__FILE__}:#{__LINE__}) \r\n#{request}"

        response = parent.http_post(request, options)

        log "[UPDATE RECEIVED] (#{__FILE__}:#{__LINE__}) \r\n#{response}"

        parse_save_response(response)
      end

      # Derives a distinct key for a compound save's secondary request (e.g. a
      # credit-note allocation or contact-group membership PUT) by suffixing the
      # caller's key. Reusing the same, caller-supplied, key for the secondary
      # request would be rejected by Xero.
      # Validated before the primary request, so an invalid key fails the whole
      # save up front.
      def derived_idempotency_key(options, suffix)
        key = Http.normalize_idempotency_key(options[:idempotency_key])
        return nil if key.nil?

        derived = "#{key}-#{suffix}"
        if derived.length > Http::MAX_IDEMPOTENCY_KEY_LENGTH
          max_base = Http::MAX_IDEMPOTENCY_KEY_LENGTH - suffix.length - 1
          raise ArgumentError,
                "idempotency_key is too long for this compound save: appending " \
                "\"-#{suffix}\" makes the secondary request's key #{derived.length} characters, " \
                "over Xero's #{Http::MAX_IDEMPOTENCY_KEY_LENGTH}-character limit. " \
                "Use a base key of at most #{max_base} characters."
        end
        derived
      end

      # Parse the response from a create/update request.
      def parse_save_response(response_xml)
        response = parent.parse_response(response_xml)
        record = response.response_items.first if response.response_items.is_a?(Array)
        if record && record.is_a?(self.class)
          @attributes = record.attributes
        end
        self
      end

      def log(what)
        Xeroizer::Logging::Log.info(what)
      end
    end
  end
end