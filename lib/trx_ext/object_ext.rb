# frozen_string_literal: true

module TrxExt
  module ObjectExt
    # Wraps specified method in an +ActiveRecord+ transaction.
    #
    # @example
    #   class Tilapia < Symbology::Base
    #     wrap_in_trx def gnosis(number)
    #       introspect(number, string.numerology(:kabbalah).sum)
    #     end
    #   end
    #
    #   order = Tilapia.new
    #   order.gnosis(93)
    #   #   (0.6ms)  BEGIN
    #   #  Introspection Load (0.4ms)  SELECT "introspections".* FROM "introspections" WHERE "introspections"."id" = $1 LIMIT 1  [["id", 93]]
    #   #   (0.2ms)  COMMIT
    #   # => 418
    #
    # @param method [Symbol] a name of the method
    # @return [Symbol]
    def wrap_in_trx(method)
      module_to_prepend = Module.new do
        class_eval <<-RUBY, __FILE__, __LINE__ + 1
        def #{method}(...)
          trx do
            super
          end
        end
        RUBY
      end
      prepend module_to_prepend
      method
    end

    # A shorthand version of <tt>ActiveRecord::Base.transaction</tt>
    def trx(...)
      ActiveRecord::Base.transaction(...)
    end
  end
end
