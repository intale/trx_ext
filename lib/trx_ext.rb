# frozen_string_literal: true

require 'active_record'
require_relative "trx_ext/callback_pool"
require_relative "trx_ext/object_ext"
require_relative "trx_ext/retry"
require_relative "trx_ext/transaction"
require_relative "trx_ext/config"
require_relative "trx_ext/version"

module TrxExt
  class << self
    attr_accessor :logger

    # @return [void]
    def integrate!
      # Allow to use #wrap_in_trx and #trx methods everywhere
      Object.prepend(TrxExt::ObjectExt)
      ActiveSupport.on_load(:active_record_mysql2adapter, &method(:integrate_into_class))
      ActiveSupport.on_load(:active_record_postgresqladapter, &method(:integrate_into_class))
      ActiveSupport.on_load(:active_record_sqlite3adapter, &method(:integrate_into_class))
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
      klass.prepend TrxExt::Transaction
      TrxExt::Retry.with_retry_until_serialized(klass, :exec_query)
      TrxExt::Retry.with_retry_until_serialized(klass, :exec_insert)
      TrxExt::Retry.with_retry_until_serialized(klass, :exec_delete)
      TrxExt::Retry.with_retry_until_serialized(klass, :exec_update)
      TrxExt::Retry.with_retry_until_serialized(klass, :exec_insert_all)
    end
  end
end

TrxExt.integrate!
