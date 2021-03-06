# frozen_string_literal: true

module JsonbAccessor
  module Macro
    module ClassMethods
      def jsonb_accessor(jsonb_attribute, field_types)
        names_and_store_keys = field_types.each_with_object({}) do |(name, type), mapping|
          _type, options = Array(type)
          mapping[name.to_s] = (options.try(:delete, :store_key) || name).to_s
        end

        # Defines virtual attributes for each jsonb field.
        field_types.each do |name, type|
          attribute name, *type
        end

        store_key_mapping_method_name = "jsonb_store_key_mapping_for_#{jsonb_attribute}"
        # Defines methods on the model class
        class_methods = Module.new do
          # Allows us to get a mapping of field names to store keys scoped to the column
          define_method(store_key_mapping_method_name) do
            superclass_mapping = superclass.try(store_key_mapping_method_name) || {}
            superclass_mapping.merge(names_and_store_keys)
          end
        end
        # We extend with class methods here so we can use the results of methods it defines to define more useful methods later
        extend class_methods

        # Get field names to default values mapping
        names_and_defaults = field_types.each_with_object({}) do |(name, type), mapping|
          _type, options = Array(type)
          field_default = options.try(:delete, :default)
          mapping[name.to_s] = field_default unless field_default.nil?
        end

        # Get store keys to default values mapping
        store_keys_and_defaults = ::JsonbAccessor::QueryBuilder.convert_keys_to_store_keys(names_and_defaults, public_send(store_key_mapping_method_name))

        # Define jsonb_defaults_mapping_for_<jsonb_attribute>
        defaults_mapping_method_name = "jsonb_defaults_mapping_for_#{jsonb_attribute}"
        class_methods.instance_eval do
          define_method(defaults_mapping_method_name) do
            superclass_mapping = superclass.try(defaults_mapping_method_name) || {}
            superclass_mapping.merge(store_keys_and_defaults)
          end
        end

        all_defaults_mapping = public_send(defaults_mapping_method_name)
        attribute jsonb_attribute, :jsonb, default: all_defaults_mapping if all_defaults_mapping.present?

        # Setters are in a module to allow users to override them and still be able to use `super`.
        setters = Module.new do
          # Overrides the setter created by `attribute` above to make sure the jsonb attribute is kept in sync.
          names_and_store_keys.each do |name, store_key|
            define_method("#{name}=") do |value|
              super(value)
              new_values = (public_send(jsonb_attribute) || {}).merge(store_key => public_send(name))
              write_attribute(jsonb_attribute, new_values)
            end
          end

          # Overrides the jsonb attribute setter to make sure the jsonb fields are kept in sync.
          define_method("#{jsonb_attribute}=") do |given_value|
            value = given_value || {}
            names_to_store_keys = self.class.public_send(store_key_mapping_method_name)

            empty_store_key_attributes = names_to_store_keys.values.each_with_object({}) { |name, defaults| defaults[name] = nil }
            empty_named_attributes = names_to_store_keys.keys.each_with_object({}) { |name, defaults| defaults[name] = nil }

            store_key_attributes = ::JsonbAccessor::QueryBuilder.convert_keys_to_store_keys(value, names_to_store_keys)
            write_attribute(jsonb_attribute, empty_store_key_attributes.merge(store_key_attributes))

            empty_named_attributes.merge(value).each { |name, attribute_value| write_attribute(name, attribute_value) }
          end
        end
        include setters

        # Makes sure new objects have the appropriate values in their jsonb fields.
        after_initialize do
          jsonb_values = public_send(jsonb_attribute) || {}
          jsonb_values.each do |store_key, value|
            name = names_and_store_keys.key(store_key)
            write_attribute(name, value) if name
          end
          clear_changes_information if persisted?
        end

        # <jsonb_attribute>_where scope
        scope("#{jsonb_attribute}_where", lambda do |attributes|
          store_key_attributes = ::JsonbAccessor::QueryBuilder.convert_keys_to_store_keys(attributes, all.model.public_send(store_key_mapping_method_name))
          jsonb_where(jsonb_attribute, store_key_attributes)
        end)

        # <jsonb_attribute>_where_not scope
        scope("#{jsonb_attribute}_where_not", lambda do |attributes|
          store_key_attributes = ::JsonbAccessor::QueryBuilder.convert_keys_to_store_keys(attributes, all.model.public_send(store_key_mapping_method_name))
          jsonb_where_not(jsonb_attribute, store_key_attributes)
        end)

        # <jsonb_attribute>_order scope
        scope("#{jsonb_attribute}_order", lambda do |attribute, direction = nil|
          key = all.model.public_send(store_key_mapping_method_name)[attribute.to_s]
          jsonb_order(jsonb_attribute, key, direction || :asc)
        end)
      end
    end
  end
end
