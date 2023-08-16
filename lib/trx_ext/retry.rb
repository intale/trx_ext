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
              ::TrxExt::Retry.retry_until_serialized do
                super
              end
            end
          RUBY
        end
        prepend module_to_prepend
        method
      end

      # Retries block execution until serialization errors are no longer raised
      def retry_until_serialized
        retries_count = 0
        begin
          yield
        rescue ActiveRecord::SerializationFailure, ActiveRecord::RecordNotUnique, ActiveRecord::Deadlocked => error
          raise unless retry_query?(error, retries_count)

          retries_count += 1 unless indisputable_retry?(error)
          TrxExt.log("Detected transaction rollback condition. Reason - #{error.inspect}. Retrying...")
          retry
        end
      end

      private

      # @param error [ActiveRecord::ActiveRecordError]
      # @return [Boolean]
      def indisputable_retry?(error)
        error.is_a?(ActiveRecord::Deadlocked) || error.is_a?(ActiveRecord::SerializationFailure)
      end

      # @param error [ActiveRecord::ActiveRecordError]
      # @param retries_count [Integer]
      # @return [Boolean]
      def retry_query?(error, retries_count)
        return true if ActiveRecord::Base.connection.open_transactions == 0 && indisputable_retry?(error)

        ActiveRecord::Base.connection.open_transactions == 0 && retries_count < TrxExt.config.unique_retries
      end
    end
  end
end
