# frozen_string_literal: true

module TrxExt
  # Implements the feature that allows you to define callbacks that will be fired after SQL transaction is complete.
  module Transaction
    # See https://api.rubyonrails.org/classes/ActiveRecord/ConnectionAdapters/DatabaseStatements.html#method-i-transaction
    # for available params
    def transaction(**kwargs, &blk)
      pool = nil
      TrxExt::Retry.retry_until_serialized(self) do
        super(**kwargs) do
          pool = TrxExt::CallbackPool.add(previous: current_callbacks_chain_link)
          self.current_callbacks_chain_link = pool
          blk.call(pool)
        end
      rescue
        self.current_callbacks_chain_link = nil
        raise
      end
    ensure
      pool.exec_callbacks_chain(connection: self)
    end

    # Returns the {TrxExt::CallbackPool} instance for the transaction that is being executed at the moment.
    def current_callbacks_chain_link
      @trx_callbacks_chain
    end

    # Set the {TrxExt::CallbackPool} instance for the transaction that is being executed at the moment.
    def current_callbacks_chain_link=(val)
      @trx_callbacks_chain = val
    end
  end
end
