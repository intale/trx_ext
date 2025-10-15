# frozen_string_literal: true

require 'active_record'
require_relative 'trx_ext/object_ext'
require_relative 'trx_ext/retry'
require_relative 'trx_ext/config'
require_relative 'trx_ext/version'

module TrxExt
  SUPPORTED_ADAPTERS = %i[
    active_record_mysql2adapter
    active_record_postgresqladapter
    active_record_sqlite3adapter
    active_record_trilogyadapter
  ].freeze

  class << self
    attr_accessor :logger

    # @return [void]
    def integrate!
      # Allow to use #wrap_in_trx and #trx methods everywhere
      Object.prepend(TrxExt::ObjectExt)
      SUPPORTED_ADAPTERS.each do |adapter_name|
        ActiveSupport.on_load(adapter_name, &method(:integrate_into_class))
      end
    end

    # @return [void]
    def log(msg)
      logger&.info(msg)
    end

    # @return [TrxExt::Config]
    def config
      @config ||= TrxExt::Config.new
    end

    def configure
      yield config
    end

    private

    def integrate_into_class(klass)
      %i[exec_query exec_insert exec_delete exec_update exec_insert_all transaction].each do |method_name|
        TrxExt::Retry.with_retry_until_serialized(klass, method_name)
      end
    end
  end
end

TrxExt.integrate!
