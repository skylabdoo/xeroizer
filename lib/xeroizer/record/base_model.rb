# frozen_string_literal: true

require 'xeroizer/record/base_model_http_proxy'

module Xeroizer
  module Record
    class BaseModel
      include ClassLevelInheritableAttributes

      class_inheritable_attributes :api_controller_name

      module InvaidPermissionError; end

      class InvalidPermissionError < XeroizerError
        include InvaidPermissionError
      end
      ALLOWED_PERMISSIONS = %i[read write update].freeze
      class_inheritable_attributes :permissions

      class_inheritable_attributes :xml_root_name
      class_inheritable_attributes :optional_xml_root_name
      class_inheritable_attributes :xml_node_name

      DEFAULT_RECORDS_PER_BATCH_SAVE = 50

      include BaseModelHttpProxy

      attr_reader :application, :model_name, :response
      attr_writer :model_class

      class << self
        # Method to allow override of the default controller name used
        # in the API URLs.
        #
        # Default: pluaralized model name (e.g. if the controller name is
        # Invoice then the default is Invoices.
        def set_api_controller_name(controller_name)
          self.api_controller_name = controller_name
        end

        # Set the permissions allowed for this class type.
        # There are no permissions set by default.
        # Valid permissions are :read, :write, :update.
        def set_permissions(*args)
          self.permissions = {}
          args.each do |permission|
            unless ALLOWED_PERMISSIONS.include?(permission)
              raise InvalidPermissionError.new("Permission #{permission} is invalid.")
            end

            permissions[permission] = true
          end
        end

        # Models that never call set_permissions have nil permissions; treat as not permitted.
        def permission?(action)
          (permissions || {})[action]
        end

        # Method to allow override of the default XML node name.
        #
        # Default: singularized model name in camel-case.
        def set_xml_node_name(node_name)
          self.xml_node_name = node_name
        end

        # Method to allow override of the default XML root name to use
        # in has_many associations.
        def set_xml_root_name(root_name)
          self.xml_root_name = root_name
        end

        # Method to add an extra top-level node to use in has_many associations.
        def set_optional_xml_root_name(optional_root_name)
          self.optional_xml_root_name = optional_root_name
        end
      end

      def initialize(application, model_name)
        @application = application
        @model_name = model_name
        @allow_batch_operations = false
        @objects = {}
      end

      # Retrieve the controller name.
      #
      # Default: pluaralized model name (e.g. if the controller name is
      # Invoice then the default is Invoices.
      def api_controller_name
        self.class.api_controller_name || model_name.pluralize
      end

      def model_class
        @model_class ||= Xeroizer::Record.const_get(model_name.to_sym)
      end

      # Build a record with attributes set to the value of attributes.
      def build(attributes = {})
        model_class.build(attributes, self).tap do |resource|
          mark_dirty(resource)
        end
      end

      def mark_dirty(resource)
        return unless @allow_batch_operations

        @objects[model_class] ||= {}
        @objects[model_class][resource.object_id] ||= resource
      end

      def mark_clean(resource)
        return unless @objects and @objects[model_class]

        @objects[model_class].delete(resource.object_id)
      end

# Create (build and save) a record.
      #
      # Pass request options in a *separate* second hash so attributes given as
      # bare keywords still land in +attributes+:
      #
      #   create(name: "Acme Ltd")                                 # attributes only
      #   create({name: "Acme Ltd"}, idempotency_key: "key-123")   # attributes + option
      #
      # A bare :idempotency_key keyword would be absorbed into +attributes+ and
      # fail with a confusing setter error, so that mistake is caught early.
      #
      # @param [Hash] attributes the new record's attributes.
      # @param [Hash] options request options forwarded to #save.
      # @option options [String] :idempotency_key (nil) sets the +Idempotency-Key+ header.
      def create(attributes = {}, options = {})
        if attributes.is_a?(Hash) && (attributes.key?(:idempotency_key) || attributes.key?('idempotency_key'))
          raise ArgumentError,
                "to pass :idempotency_key to create, wrap the attributes in braces so it " \
                "is not absorbed as a record attribute: " \
                "create({ ... }, idempotency_key: \"...\")"
        end
        build(attributes).tap { |resource| resource.save(options) }
      end

      # Retrieve full record list for this model.
      def all(options = {})
        raise MethodNotAllowed.new(self, :all) unless self.class.permission?(:read)

        response_xml = http_get(parse_params(options))
        response = parse_response(response_xml, options)
        response.response_items || []
      end

      # allow invoices to be process in batches of 100 as per xero documentation
      # https://developer.xero.com/documentation/api/invoices/
      def find_in_batches(options = {})
        options[:page] ||= 1
        while results = all(options)
          break unless results.any?

          yield results
          options[:page] += 1

        end
      end

      # Helper method to retrieve just the first element from
      # the full record list.
      def first(options = {})
        raise MethodNotAllowed.new(self, :all) unless self.class.permission?(:read)

        result = all(options)
        result.first if result.is_a?(Array)
      end

      # Retrieve record matching the passed in ID.
      def find(id, options = {})
        raise MethodNotAllowed.new(self, :all) unless self.class.permission?(:read)

        response_xml = @application.http_get(@application.client, "#{url}/#{CGI.escape(id)}", options)
        response = parse_response(response_xml, options)
        result = response.response_items.first if response.response_items.is_a?(Array)
        result.complete_record_downloaded = true if result
        result
      end

      # @param [String, #call] idempotency_key sets the +Idempotency-Key+ header.
      #   A batch fans out into one request per chunk and verb (creates PUT, updates
      #   POST), each needing its own key:
      #   * a String is allowed only for a SINGLE-request batch (one chunk, one verb).
      #   * a callable is required for MULTI-request batches. Invoked per request as
      #     <tt>(records, http_method)</tt> (fewer args also allowed), it must derive
      #     the key from the records' stable identity, NOT their position. On a retry
      #     the requests re-chunk (saved records become updates), so a position-based
      #     key would move onto the wrong records while a content-derived key stays
      #     bound.
      #     
      #   RETRY-SAFETY CAVEAT: this holds only when a retry reconstructs IDENTICAL
      #   requests. It does NOT when a responded chunk had mixed per-record outcomes
      #   (Xero saved some records, rejected others): a rejected record stays a create
      #   and shifts the chunk boundaries behind it, so on retry those records get
      #   different keys and records Xero already created can be created again.
      def save_records(records, chunk_size = DEFAULT_RECORDS_PER_BATCH_SAVE, idempotency_key: nil)
        no_errors = true
        return false unless records.all?(&:valid?)
        raise ArgumentError, "chunk_size must be a positive integer" unless chunk_size.is_a?(Integer) && chunk_size > 0

# One [records, http_method] pair per HTTP request: creates (PUT) and
        # updates (POST) split by verb, then each chunk is its own request.
        request_units = records
          .group_by { |o| o.new_record? ? create_method : :http_post }
          .flat_map { |http_method, recs| recs.each_slice(chunk_size).map { |slice| [slice, http_method] } }

        # Resolve all keys up front so an unsatisfiable key set rejects the whole
        # batch before anything is sent, rather than failing mid-batch.
        request_keys = resolve_batch_idempotency_keys(idempotency_key, request_units)

        request_units.each_with_index do |(some_records, http_method), request_index|
          request = to_bulk_xml(some_records)
          request_params = { summarizeErrors: false }
          request_params[:idempotency_key] = request_keys[request_index] if request_keys
          response = parse_response(send(http_method, request, request_params))
          response.response_items.each_with_index do |record, i|
            next unless record.is_a?(model_class)

            some_records[i].attributes = record.non_calculated_attributes
            some_records[i].errors = record.errors
            no_errors = record.errors.blank? if no_errors
            some_records[i].saved!
          end
        end

        no_errors
      end

      def batch_save(chunk_size = DEFAULT_RECORDS_PER_BATCH_SAVE, idempotency_key: nil)
        @objects = {}
        @allow_batch_operations = true

        begin
          yield

          if @objects[model_class]
            objects = @objects[model_class].values.compact
            save_records(objects, chunk_size, idempotency_key: idempotency_key)
          end
        ensure
          @objects = {}
          @allow_batch_operations = false
        end
      end

      def parse_response(response_xml, options = {})
        Response.parse(response_xml, options) do |response, elements, response_model_name|
          if model_name == response_model_name
            @response = response
            parse_records(response, elements, paged_records_requested?(options), options[:base_module] || Xeroizer::Record)
          end
        end
      end

      def create_method
        :http_put
      end

      protected

      def paged_records_requested?(options)
        options.key?(:page) and options[:page].to_i >= 0
      end

      # Parse the records part of the XML response and builds model instances as necessary.
      def parse_records(response, elements, paged_results, base_module)
        elements.each do |element|
          new_record = model_class.build_from_node(element, self, base_module)
          if element.attribute('status').try(:value) == 'ERROR'
            new_record.errors = []
            element.xpath('.//ValidationError').each do |err|
              new_record.errors << err.text.gsub(/^\s+/, '').gsub(/\s+$/, '')
            end
          end
          new_record.paged_record_downloaded = paged_results
          response.response_items << new_record
        end
      end

      def to_bulk_xml(records, builder = Builder::XmlMarkup.new(indent: 2))
        tag = (self.class.optional_xml_root_name || model_name).pluralize
        builder.tag!(tag) do
          records.each { |r| r.to_xml(builder) }
        end
      end

      # Returns nil when no key was given, or one validated String key per request
      # unit (in send order). Raises ArgumentError on a key set Xero would reject.
      def resolve_batch_idempotency_keys(idempotency_key, request_units)
        return nil if idempotency_key.nil? || request_units.empty?

        if idempotency_key.respond_to?(:call)
          generated_batch_idempotency_keys(idempotency_key, request_units)
        else
          static_batch_idempotency_key(idempotency_key, request_units.size)
        end
      end

      # A String key is valid only for a single-request batch (Xero rejects a
      # reused key on a different request). Returned Array-wrapped, one per request.
      def static_batch_idempotency_key(idempotency_key, request_count)
        if request_count > 1
          raise ArgumentError,
            "save_records will send #{request_count} requests but was given a single " \
            "idempotency_key; Xero rejects a reused key on a different request. Pass a " \
            "callable (e.g. ->(records, http_method) { ... }) to generate a unique key " \
            "per request, or increase chunk_size so the batch fits in one request."
        end

        [Http.normalize_idempotency_key(idempotency_key)]
      end

      # Invoke the generator per request and validate each key through the SAME
      # rules as a single-request key (non-String, blank, or over-length raise),
      # with allow_nil: false so a generator that returns nothing for a request
      # raises rather than sending it unkeyed. Plus a batch-only uniqueness check.
      def generated_batch_idempotency_keys(generator, request_units)
        invoke = batch_key_generator_invoker(generator)

        keys = request_units.map do |records, http_method|
          Http.normalize_idempotency_key(invoke.call(records, http_method), allow_nil: false)
        end

        if keys.uniq.size != keys.size
          raise ArgumentError,
            "idempotency_key generator returned duplicate keys; Xero rejects a reused " \
            "key on a different request. Return a unique key per request."
        end

        keys
      end

      # Returns a proc that calls +callable+ with as many of (records, http_method)
      # as its signature accepts; raises up front for a signature we can't satisfy.
      #
      # Uses #parameters, not #arity: a lambda with an optional positional arg
      # reports a negative arity (->(records = nil){} is -1) yet rejects a second
      # arg, while a splat (->(*args){}) also reports negative but accepts both —
      # only #parameters distinguishes them.
      def batch_key_generator_invoker(callable)
        parameters = (callable.respond_to?(:parameters) ? callable : callable.method(:call)).parameters

        # A declared keyword param can't receive a positional value, so it would
        # silently drop http_method — reject it. A bare **rest receives nothing
        # and is fine.
        if parameters.any? { |type, _name| type == :keyreq || type == :key }
          raise ArgumentError,
            "idempotency_key generator must accept (records, http_method) positionally; " \
            "keyword parameters are not supported. Define it as " \
            "->(records, http_method) { ... } (fewer positionals are fine)."
        end

        # A splat accepts everything we have — pass both.
        return ->(records, http_method) { callable.call(records, http_method) } if parameters.any? { |type, _name| type == :rest }

        required_positional = parameters.count { |type, _name| type == :req }
        if required_positional > 2
          raise ArgumentError,
            "idempotency_key generator requires #{required_positional} positional arguments " \
            "but the batch helper supplies at most two (records, http_method). Define it " \
            "with at most two positional parameters."
        end

        arg_count = [parameters.count { |type, _name| type == :req || type == :opt }, 2].min
        ->(records, http_method) { callable.call(*[records, http_method].first(arg_count)) }
      end

      # Parse the response from a create/update request.
      def parse_save_response(response_xml)
        response = parse_response(response_xml)
        record = response.response_items.first if response.response_items.is_a?(Array)
        if record && record.is_a?(self.class)
          @attributes = record.attributes
        end
        self
      end
    end
  end
end
