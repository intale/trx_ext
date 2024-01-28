# frozen_string_literal: true

module TrxExt
  module Retry
    class RetryLimitExceeded < StandardError
      attr_reader :original_error

      def initialize(original_error)
        @original_error = original_error
        super("Retries limit of #{TrxExt.config.unique_retries} has exceeded")
      end
    end

    class << self
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
          raise RetryLimitExceeded.new(error) unless retry_query?(connection, retries_count)

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
