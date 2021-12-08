# frozen_string_literal: true

module TrxExt
  class CallbackPool
    class << self
      # @param :previous [nil, TrxExt::CallbackPool]
      # @return [TrxExt::CallbackPool]
      def add(previous: nil)
        # It may happen when transaction is defined inside `on_complete` callback and, thus, when adding the
        # `on_complete` callback for it, `previous` will point on the `TrxExt::CallbackPool` of the transaction's
        # callback that is being executing right now. We should not continue such chain and allow the transaction to
        # build its own chain.
        # Example:
        #   trx do |c1|
        #     c1.on_complete do
        #       # When executing .add to define c2 TrxExt::CallbackPool - previous argument will contain
        #       # c1 TrxExt::CallbackPool that is already being executing. Assign nil to previous in this case.
        #       trx do |c2|
        #         c2.on_complete { }
        #       end
        #     end
        #   end
        previous = nil if previous&.locked_for_execution?
        inst = new
        inst.previous = previous
        inst
      end
    end

    # Points on the previous instance in the single linked chain
    attr_accessor :previous
    attr_writer :locked_for_execution

    def initialize
      @callbacks = []
      @locked_for_execution = false
    end

    # @return [Boolean] whether current instance is locked for the next {#exec_callbacks} action
    def locked_for_execution?
      @locked_for_execution
    end

    # @param blk [Proc]
    # @return [void]
    def on_complete(&blk)
      @callbacks.push(blk)
    end

    # The chain of callbacks pool comes as follows:
    # <#TrxExt::CallbackPool:0x03 @callbacks=[] previous=
    #   <#TrxExt::CallbackPool:0x02 @callbacks=[] previous=
    #     <#TrxExt::CallbackPool:0x01 @callbacks=[] previous=nil>
    #   >
    # >
    # The most inner instance - is the instance that was created first in stack call. The most top instance - is the
    # instance that was created last in the stack call.
    # Related example of how they are created during `trx` calls:
    #   trx do |c0x01|
    #     trx do |c0x02|
    #       trx do |c0x03|
    #       end
    #     end
    #   end
    #
    # At the end of execution of each `trx` - {#exec_callbacks_chain} will be called for each {TrxExt::CallbackPool}.
    # But only <#TrxExt::CallbackPool:0x01> will really execute the callbacks of all pools in the chain - only it has
    # rights to do this, because only it stands on the top of the call stack. This is ensured with
    # `return unless previous.nil?` condition. At the moment of execution of {#exec_callbacks_chain} of top-stack
    # instance - {ActiveRecord::Base.connection.current_callbacks_chain_link} points on the most inner, by call stack,
    # {TrxExt::CallbackPool}. In the example above, it is <#TrxExt::CallbackPool:0x03>
    #
    # @param :connection [ActiveRecord::ConnectionAdapters::PostgreSQLAdapter]
    # @return [Boolean] whether callbacks was executed
    def exec_callbacks_chain(connection:)
      return false unless previous.nil?

      current = connection.current_callbacks_chain_link
      loop do
        # It is important to keep it here to prevent potential
        # `NoMethodError: undefined method `exec_callbacks' for nil:NilClass` exception when trying to execute callbacks
        # for the transaction that raised an exception. In case of exception - current_callbacks_chain_link is set to
        # nil. See {TrxExt::Retry.retry_until_serialized}. See {TrxExt::Transaction#transaction}.
        # Example:
        #   trx { raise "trol" } # Should raise RuntimeError instead of NoMethodError
        break if current.nil?

        current.locked_for_execution = true
        current.exec_callbacks
        current = current.previous
      end
      # Can't use `ensure` here, because it will be triggered even if condition in first line is falsey. And we need
      # to set connection#current_callbacks_chain_link to nil only in case of exception or in case of successful run of
      # callbacks
      connection.current_callbacks_chain_link = nil
      true
    rescue
      connection.current_callbacks_chain_link = nil
      raise
    end

    # @return [void]
    def exec_callbacks
      @callbacks.each(&:call)
      nil
    end
  end
end
