# frozen_string_literal: true

module TrxExt
  module Retry
    class << self
      # Wraps specified method in a +TrxExt::Retry.retry_until_serialized+ loop.
      #
      # @param klass [Class] class a method belongs to
      # @param method [Symbol] instance method that needs to be wrapped into +TrxExt::Retry.retry_until_serialized+
      def with_retry_until_serialized(klass, method)
        module_to_prepend = Module.new do
          klass.class_eval <<-RUBY, __FILE__, __LINE__ + 1
            def #{method}(...)
              ::TrxExt::Retry.retry_until_serialized(self) do
                super
              end
            end
          RUBY
        end
        prepend module_to_prepend
        method
      end

      # Retries block execution until serialization errors are no longer raised
      def retry_until_serialized(connection)
        retries_count = 0
        begin
          yield
        rescue ActiveRecord::SerializationFailure, ActiveRecord::Deadlocked => error
          if connection.open_transactions == 0
            TrxExt.log("Detected transaction rollback condition. Reason - #{error.inspect}. Retrying...")
            retry
          end
          raise
        rescue ActiveRecord::RecordNotUnique => error
          raise unless retry_query?(connection, retries_count)

          retries_count += 1
          TrxExt.log("Detected transaction rollback condition. Reason - #{error.inspect}. Retrying...")
          retry
        end
      end

      private

      # @param connection
      # @param retries_count [Integer]
      # @return [Boolean]
      def retry_query?(connection, retries_count)
        connection.open_transactions == 0 && retries_count < TrxExt.config.unique_retries
      end
    end
  end
end
