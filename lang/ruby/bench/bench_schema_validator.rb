$LOAD_PATH << File.join(File.expand_path(File.dirname(__FILE__)), '..', 'lib')

require 'benchmark/ips'
require 'avro'

Benchmark.ips do |x|
  x.config(:time => 5, :warmup => 2)

  schema = ::Avro::Schema.parse({
    name: 'User',
    type: 'record',
    fields: [
      {name: 'guid', type: ['null','string']},
      {name: 'id', type: ['null','string']},
      {name: 'first_name', type: ['null','string']},
      {name: 'is_disabled', type: ['null','boolean']},
      {name: 'last_name', type: ['null','string']},
      {name: 'logged_in_at', type: ['null','long']},
      {name: 'gender', type: ['null','string']},
      {name: 'birthdate', type: ['null','string']},
      {name: 'birthday', type: ['null','string']},
      {name: 'zip_code', type: ['null','string']},
      {name: 'email', type: ['null','string']},
      {name: 'phone', type: ['null','string']},
      {name: 'postal_code', type: ['null','string']},
      {name: 'revision', type:['null','long']},
      {name: 'updated_at', type:['null','long']},
      {name: 'metadata', type:['null','string']},
    ]
  }.to_json)

  value = {
    guid: "abc",
    id: "123",
    first_name: "fname",
    is_disabled: false,
    last_name: "lname",
    logged_in_at: 123,
    gender: "m",
    birthdate: "dob",
    birthday: "today",
    zip_code: "12312",
    email: "ab@c",
    phone: "123",
    postal_code: "123",
    revision: 321,
    updated_at: 321,
    metadata: "",
  }

  v1_options = { recursive: true, encoded: false, fail_on_extra_fields: false, use_original_impl: true }
  v2_options = { recursive: true, encoded: false, fail_on_extra_fields: false, use_original_impl: false }

  x.report('fail on type error') do |times|
    Avro::SchemaValidator.validate!(schema, value, v1_options)
  end

  x.report('inlined error build') do |times|
    Avro::SchemaValidator.validate!(schema, value, v2_options)
  end

  x.compare!
end

# ~/code/mx/avro/lang/ruby $ bx ruby bench/bench_schema_validator.rb
# Warming up --------------------------------------
#   fail on type error   749.000  i/100ms
#  inlined error build     1.336k i/100ms
# Calculating -------------------------------------
#   fail on type error     11.235M (±11.9%) i/s -     53.302M in   4.921379s
#  inlined error build     19.596M (±10.1%) i/s -     94.554M in   4.925544s
#
# Comparison:
#  inlined error build: 19596112.6 i/s
#   fail on type error: 11234743.2 i/s - 1.74x  slower
#
# ~/code/mx/avro/lang/ruby $ ruby --version
# jruby 9.2.7.0 (2.5.3) 2019-04-09 8a269e3 Java HotSpot(TM) 64-Bit Server VM 25.171-b11 on 1.8.0_171-b11 +jit [darwin-x86_64]
