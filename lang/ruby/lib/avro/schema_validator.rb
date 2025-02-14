# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
# https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

module Avro
  class SchemaValidator
    ROOT_IDENTIFIER = '.'.freeze
    PATH_SEPARATOR = '.'.freeze
    INT_RANGE = Schema::INT_MIN_VALUE..Schema::INT_MAX_VALUE
    LONG_RANGE = Schema::LONG_MIN_VALUE..Schema::LONG_MAX_VALUE
    COMPLEX_TYPES = [:array, :error, :map, :record, :request].freeze
    BOOLEAN_VALUES = [true, false].freeze

    class Result
      attr_reader :errors

      def initialize
        @errors = []
      end

      def <<(error)
        @errors << error
      end

      def add_error(path, message)
        self << "at #{path} #{message}"
      end

      def failure?
        @errors.any?
      end

      def to_s
        errors.join("\n")
      end
    end

    class ValidationError < StandardError
      attr_reader :result

      def initialize(result = Result.new)
        @result = result
        super
      end

      def to_s
        result.to_s
      end
    end

    TypeMismatchError = Class.new(ValidationError)

    class << self
      def validate!(expected_schema, logical_datum, options = { recursive: true, encoded: false, fail_on_extra_fields: false })
        options ||= {}
        options[:recursive] = true unless options.key?(:recursive)

        result = Result.new
        if options[:recursive]
          validate_recursive(expected_schema, logical_datum, ROOT_IDENTIFIER, result, options)
        else
          validate_simple(expected_schema, logical_datum, ROOT_IDENTIFIER, result, options)
        end
        fail ValidationError, result if result.failure?
        result
      end

      private

      def validate_recursive(expected_schema, logical_datum, path, result, options = {})
        datum = resolve_datum(expected_schema, logical_datum, options[:encoded])

        validate_simple(expected_schema, datum, path, result, encoded: true)

        case expected_schema.type_sym
        when :array
          validate_array(expected_schema, datum, path, result, options)
        when :map
          validate_map(expected_schema, datum, path, result, options)
        when :union
          validate_union(expected_schema, datum, path, result, options)
        when :record, :error, :request
          fail TypeMismatchError unless datum.is_a?(Hash)
          expected_schema.fields.each do |field|
            deeper_path = deeper_path_for_hash(field.name, path)
            validate_recursive(field.type, datum[field.name], deeper_path, result, options)
          end
          if options[:fail_on_extra_fields]
            datum_fields = datum.keys.map(&:to_s)
            schema_fields = expected_schema.fields.map(&:name)
            (datum_fields - schema_fields).each do |extra_field|
              result.add_error(path, "extra field '#{extra_field}' - not in schema")
            end
          end
        end
      rescue TypeMismatchError
        result.add_error(path, "expected type #{expected_schema.type_sym}, got #{actual_value_message(datum)}")
      end

      def validate_simple(expected_schema, logical_datum, path, result, options = {})
        datum = resolve_datum(expected_schema, logical_datum, options[:encoded])
        validate_type(expected_schema)

        case expected_schema.type_sym
        when :null
          return if datum.nil?
          result.add_error(path, "expected type #{expected_schema.type_sym}, got #{actual_value_message(datum)}")
          return
        when :boolean
          return if BOOLEAN_VALUES.include?(datum)
          result.add_error(path, "expected type #{expected_schema.type_sym}, got #{actual_value_message(datum)}")
          return
        when :string, :bytes
          return if datum.is_a?(String)
          result.add_error(path, "expected type #{expected_schema.type_sym}, got #{actual_value_message(datum)}")
          return
        when :int
          if datum.is_a?(Integer)
            result.add_error(path, "out of bound value #{datum}") unless INT_RANGE.cover?(datum)
            return
          end
          result.add_error(path, "expected type #{expected_schema.type_sym}, got #{actual_value_message(datum)}")
          return
        when :long
          if datum.is_a?(Integer)
            result.add_error(path, "out of bound value #{datum}") unless LONG_RANGE.cover?(datum)
            return
          end
          result.add_error(path, "expected type #{expected_schema.type_sym}, got #{actual_value_message(datum)}")
          return
        when :float, :double
          return if datum.is_a?(Float) || datum.is_a?(Integer)
          result.add_error(path, "expected type #{expected_schema.type_sym}, got #{actual_value_message(datum)}")
          return
        when :fixed
          if datum.is_a? String
            result.add_error(path, fixed_string_message(expected_schema.size, datum)) unless datum.bytesize == expected_schema.size
          else
            result.add_error(path, "expected fixed with size #{expected_schema.size}, got #{actual_value_message(datum)}")
          end
          return
        when :enum
          result.add_error(path, enum_message(expected_schema.symbols, datum)) unless expected_schema.symbols.include?(datum)
          return

          # when :array
          #   return
          # when :record
          #   return
          # when :map
          #   return
          # when :union
          #   return

        end
        # rescue TypeMismatchError
        #   result.add_error(path, "expected type #{expected_schema.type_sym}, got #{actual_value_message(datum)}")

        # result.add_error(path, "expected type #{expected_schema.type_sym}, got #{actual_value_message(datum)}")
      end

      def resolve_datum(expected_schema, logical_datum, encoded)
        if encoded
          logical_datum
        else
          expected_schema.type_adapter.encode(logical_datum) rescue nil
        end
      end

      def validate_type(expected_schema)
        unless Avro::Schema::VALID_TYPES_SYM.include?(expected_schema.type_sym)
          fail "Unexpected schema type #{expected_schema.type_sym} #{expected_schema.inspect}"
        end
      end

      def fixed_string_message(size, datum)
        "expected fixed with size #{size}, got \"#{datum}\" with size #{datum.bytesize}"
      end

      def enum_message(symbols, datum)
        "expected enum with values #{symbols}, got #{actual_value_message(datum)}"
      end

      def validate_array(expected_schema, datum, path, result, options = {})
        fail TypeMismatchError unless datum.is_a?(Array)
        datum.each_with_index do |d, i|
          validate_recursive(expected_schema.items, d, path + "[#{i}]", result, options)
        end
      end

      def validate_map(expected_schema, datum, path, result, options = {})
        fail TypeMismatchError unless datum.is_a?(Hash)
        datum.keys.each do |k|
          result.add_error(path, "unexpected key type '#{ruby_to_avro_type(k.class)}' in map") unless k.is_a?(String)
        end
        datum.each do |k, v|
          deeper_path = deeper_path_for_hash(k, path)
          validate_recursive(expected_schema.values, v, deeper_path, result, options)
        end
      end

      def validate_union(expected_schema, datum, path, result, options = {})
        if expected_schema.schemas.size == 1
          validate_recursive(expected_schema.schemas.first, datum, path, result, options)
          return
        end
        failures = []
        compatible_type = first_compatible_type(datum, expected_schema, path, failures, options)
        return unless compatible_type.nil?

        complex_type_failed = failures.detect { |r| COMPLEX_TYPES.include?(r[:type]) }
        if complex_type_failed
          complex_type_failed[:result].errors.each { |error| result << error }
        else
          types = expected_schema.schemas.map { |s| "'#{s.type_sym}'" }.join(', ')
          result.add_error(path, "expected union of [#{types}], got #{actual_value_message(datum)}")
        end
      end

      def first_compatible_type(datum, expected_schema, path, failures, options = {})
        expected_schema.schemas.find do |schema|
          result = Result.new
          validate_recursive(schema, datum, path, result, options)
          failures << { type: schema.type_sym, result: result } if result.failure?
          !result.failure?
        end
      end

      def deeper_path_for_hash(sub_key, path)
        "#{path}#{PATH_SEPARATOR}#{sub_key}".squeeze(PATH_SEPARATOR)
      end

      def actual_value_message(value)
        avro_type = if value.is_a?(Integer)
                      ruby_integer_to_avro_type(value)
                    else
                      ruby_to_avro_type(value.class)
                    end
        if value.nil?
          avro_type
        else
          "#{avro_type} with value #{value.inspect}"
        end
      end

      def ruby_to_avro_type(ruby_class)
        {
          NilClass => 'null',
          String => 'string',
          Float => 'float',
          Hash => 'record'
        }.fetch(ruby_class, ruby_class)
      end

      def ruby_integer_to_avro_type(value)
        INT_RANGE.cover?(value) ? 'int' : 'long'
      end
    end
  end
end
