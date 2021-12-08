# frozen_string_literal: true

require 'active_support'
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
      ActiveSupport.on_load(:active_record) do
        require 'active_record/connection_adapters/postgresql_adapter'

        # Allow to use #wrap_in_trx and #trx methods everywhere
        Object.prepend(TrxExt::ObjectExt)

        # Patch #transaction
        ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.prepend(TrxExt::Transaction)

        # Single SELECT/UPDATE/DELETE queries should also be retried even if they are not a part of explicit transaction
        TrxExt::Retry.with_retry_until_serialized(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter, :exec_query)
        TrxExt::Retry.with_retry_until_serialized(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter, :exec_update)
        TrxExt::Retry.with_retry_until_serialized(ActiveRecord::ConnectionAdapters::PostgreSQLAdapter, :exec_delete)
      end
    end

    # @return [void]
    def log(msg)
      return unless logger

      logger.info(msg)
    end

    # @return [TrxExt::Config]
    def config
      @config ||= TrxExt::Config.new
    end

    def configure
      yield config
    end
  end
end

if defined?(Rails::Railtie)
  require_relative "trx_ext/railtie"
else
  TrxExt.integrate!
end
