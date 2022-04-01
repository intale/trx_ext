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
        rescue => error
          error_classification = error_classification(error)
          if retry_query?(error, retries_count)
            if error_classification == :record_not_unique
              retries_count += 1
            end
            TrxExt.log("Detected transaction rollback condition. Reason - #{error_classification}. Retrying...")
            retry
          else
            raise error
          end
        end
      end

      private

      def error_classification(error)
        case
        when error.message.index('deadlock detected')
          :deadlock
        when error.message.index('could not serialize')
          :serialization_error
        when error.class == ActiveRecord::RecordNotUnique
          :record_not_unique
        end
      end

      def retry_query?(error, retryies_count)
        classification = error_classification(error)
        ActiveRecord::Base.connection.open_transactions == 0 &&
          (%i(deadlock serialization_error).include?(classification) ||
            classification == :record_not_unique && retryies_count < TrxExt.config.unique_retries)
      end
    end
  end
end
