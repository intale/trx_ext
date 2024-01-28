# frozen_string_literal: true

module TrxExt
  module AbstractAdapterExt
    def self.included(klass)
      super
      klass.extend(ClassMethods)
    end

    module ClassMethods
      def inherited(klass)
        super
        klass.prepend Transaction
        klass.prepend SingleQueryRetries
      end
    end

    module SingleQueryRetries
      def exec_query(...)
        ::TrxExt::Retry.retry_until_serialized(self) do
          super
        end
      end

      def exec_delete(...)
        ::TrxExt::Retry.retry_until_serialized(self) do
          super
        end
      end

      def exec_update(...)
        ::TrxExt::Retry.retry_until_serialized(self) do
          super
        end
      end
    end
  end
end
