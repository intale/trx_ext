# frozen_string_literal: true

require 'active_record'
require_relative "trx_ext/callback_pool"
require_relative "trx_ext/object_ext"
require_relative "trx_ext/abstract_adapter_ext"
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

      require 'active_record/connection_adapters/abstract_adapter'
      ActiveRecord::ConnectionAdapters::AbstractAdapter.include(TrxExt::AbstractAdapterExt)
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
  end
end

TrxExt.integrate!
