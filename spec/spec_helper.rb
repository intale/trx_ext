# frozen_string_literal: true

ENV['RACK_ENV'] ||= 'test'

require 'trx_ext'
require 'factory_bot'
require 'timecop'
require 'rspec/its'
require 'active_record'

Dir[File.expand_path('support/**/*.rb', __dir__)].each { |f| require(f) }

logger = ActiveSupport::Logger.new('log/test.log')
ActiveRecord::Base.logger = logger
TrxExt.logger = logger
Time.zone = ActiveSupport::TimeZone['UTC']

# See http://rubydoc.info/gems/rspec-core/RSpec/Core/Configuration
RSpec.configure do |config|
  # rspec-expectations config goes here. You can use an alternate
  # assertion/expectation library such as wrong or the stdlib/minitest
  # assertions if you prefer.
  config.expect_with :rspec do |expectations|
    # This option will default to `true` in RSpec 4. It makes the `description`
    # and `failure_message` of custom matchers include text for helper methods
    # defined using `chain`, e.g.:
    #     be_bigger_than(2).and_smaller_than(4).description
    #     # => "be bigger than 2 and smaller than 4"
    # ...rather than:
    #     # => "be bigger than 2"
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  # rspec-mocks config goes here. You can use an alternate test double
  # library (such as bogus or mocha) by changing the `mock_with` option here.
  config.mock_with :rspec do |mocks|
    # Prevents you from mocking or stubbing a method that does not exist on
    # a real object. This is generally recommended, and will default to
    # `true` in RSpec 4.
    mocks.verify_partial_doubles = true
  end

  if config.files_to_run.one?
    # Use the documentation formatter for detailed output,
    # unless a formatter has already been configured
    # (e.g. via a command-line flag).
    config.default_formatter = 'doc'
  end

  # This option will default to `:apply_to_host_groups` in RSpec 4 (and will
  # have no way to turn it off -- the option exists only for backwards
  # compatibility in RSpec 3). It causes shared context metadata to be
  # inherited by the metadata hash of host groups and examples, rather than
  # triggering implicit auto-inclusion in groups with matching metadata.
  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.disable_monkey_patching!
  config.order = :random
  config.seed = Kernel.srand % 0xFFFF

  config.before(:suite) { DummyRecord.setup }
  config.before(:suite) do
    FactoryBot.find_definitions
  end

  config.after(:each) do
    DummyRecord.delete_all
  end

  config.around(timecop: :present?.to_proc) do |example|
    if example.metadata[:timecop].is_a? Time
      Timecop.freeze(example.metadata[:timecop]) { example.run }
    else
      Timecop.freeze { example.run }
    end
  end
end
