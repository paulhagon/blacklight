# frozen_string_literal: true

module Blacklight
  class Configuration
    # This mixin provides Blacklight::Configuration with generic
    # solr fields configuration
    module Fields
      extend ActiveSupport::Concern

      class_methods do
        # Add a configuration block for a collection of solr fields
        def define_field_access(key, base_class_name = nil, class: nil)
          key = key.to_s if respond_to? :to_s

          default_values[key.pluralize.to_sym] = ActiveSupport::HashWithIndifferentAccess.new

          @field_type_for_class ||= {}
          @field_type_for_class[key] = binding.local_variable_get(:class) || base_class_name

          class_eval <<-END_EVAL, __FILE__, __LINE__ + 1
            def add_#{key}(*args, &block)
              add_blacklight_field("#{key}", *args, &block)
            end
          END_EVAL
        end

        def field_type_for_class(key)
          @field_type_for_class&.dig(key.to_s) || Blacklight::Configuration::Field
        end
      end
      # Add a solr field configuration to the given configuration key
      #
      # The recommended and strongly encouraged format is a field name, configuration pair, e.g.:
      #     add_blacklight_field :index_field, 'format', :label => 'Format'
      #
      # Alternative formats include:
      #
      # * a field name and block format:
      #
      # @overload add_blacklight_field(config_key, field_key)
      #   @param [Symbol] config_key
      #   @param [Symbol,String] field_key
      #
      #
      #     add_blacklight_field :index_field, 'format' do |field|
      #       field.label = 'Format'
      #     end
      #
      # * a plain block:
      #
      # @overload add_blacklight_field(config_key)
      #   @param [Symbol] config_key
      #
      #     add_blacklight_field :index_field do |field|
      #       field.field = 'format'
      #       field.label = 'Format'
      #     end
      #
      # * a configuration hash:
      #
      # @overload add_blacklight_field(config_key, options)
      #   @param [Symbol] config_key
      #   @param [Hash] options
      #
      #     add_blacklight_field :index_field, :field => 'format', :label => 'Format'
      #
      # * a Field instance:
      #
      # @overload add_blacklight_field(config_key, field)
      #   @param [Symbol] config_key
      #   @param [Blacklight::Configuration::Field] field
      #
      #
      #     add_blacklight_field :index_field, IndexField.new(:field => 'format', :label => 'Format')
      #
      # * an array of hashes:
      #
      # @overload add_blacklight_field(config_key, fields)
      #   @param [Symbol] config_key
      #   @param [Array<Blacklight::Configuration::Field, Hash>] fields
      #
      #     add_blacklight_field :index_field, [{ :field => 'format', :label => 'Format' }, IndexField.new(:field => 'date', :label => 'Date')]
      #
      def add_blacklight_field(config_key, *args, &)
        field_config = case args.first
                       when String
                         field_config_from_key_and_hash(config_key, *args)
                       when Symbol
                         args[0] = args[0].to_s
                         field_config_from_key_and_hash(config_key, *args)
                       when Array
                         field_config_from_array(config_key, *args, &)
                         return # we've iterated over the array above.
                       else
                         field_config_from_field_or_hash(config_key, *args)
                       end

        if (field_config.field || field_config.key).to_s =~ /\*/
          field_config.match = Regexp.new("^#{(field_config.field || field_config.key).to_s.gsub('*', '.+')}$")
        end

        # look up any dynamic fields
        if field_config.match
          handle_matching_fields(config_key, field_config, &)
          return
        end

        if block_given?
          yield field_config
        end

        field_config.normalize!(self)
        field_config.validate!

        raise "A #{config_key} with the key #{field_config.key} already exists." if self[config_key.pluralize][field_config.key].present?

        self[config_key.pluralize][field_config.key] = field_config
      end

      private

      ##
      # Using reflection into the index, add any fields in the index that match the field_config
      def handle_matching_fields(config_key, field_config, &block)
        salient_fields = reflected_fields.select do |k, _v|
          k =~ field_config.match
        end

        salient_fields.each_key do |field|
          config = field_config.dup
          config.match = nil
          config.field = field
          config.key = field
          if self[config_key.pluralize][config.key]
            self[config_key.pluralize][config.key] = config.merge(self[config_key.pluralize][config.key])
          else
            add_blacklight_field(config_key, config, &block)
          end
        end
      end

      def reflected_fields
        if @table[:reflected_fields] == false
          return nil
        end

        @table[:reflected_fields] ||= Rails.cache.fetch("blacklight_configuration/admin/reflected_fields", expires_in: 1.hour) do
          repository.reflect_fields
        rescue => e
          Blacklight.logger&.warn "Error retrieving field metadata: #{e}"
          false
        end

        @table[:reflected_fields] || {}
      end

      # Add a solr field by a solr field name and hash
      def field_config_from_key_and_hash config_key, field_name, field_or_hash = {}
        field_config = field_config_from_field_or_hash(config_key, field_or_hash)
        field_config.key = field_name
        field_config
      end

      # Add multiple solr fields using a hash or Field instance
      def field_config_from_array config_key, array_of_fields_or_hashes, &block
        array_of_fields_or_hashes.map do |field_or_hash|
          add_blacklight_field(config_key, field_or_hash, &block)
        end
      end

      # Add a solr field using a hash or Field instance
      def field_config_from_field_or_hash config_key, field_or_hash = {}
        hash_arg_to_config(field_or_hash, field_class_from_key(config_key))
      end

      # for our add_* methods, takes the optional hash param,
      # and makes it into a specific config OpenStruct, like
      # FacetField or SearchField. Or if the param already was
      # one, that's cool. Or if the param is nil, make
      # an empty one. Second argument is an actual class object.
      def hash_arg_to_config(hash_arg, klass)
        case hash_arg
        when Hash
          klass.new(hash_arg)
        when NilClass
          klass.new
        else
          # this assumes it already is an element of klass, or acts like one,
          # if not something bad will happen later, that's your problem.
          hash_arg
        end
      end

      # convert a config key to the appropriate Field class
      # @param [String] key
      def field_class_from_key(key)
        self.class.field_type_for_class(key)
      end
    end
  end
end
