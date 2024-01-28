# frozen_string_literal: true

module TrxExt
  module ObjectExt
    # Wraps specified method in an +ActiveRecord+ transaction.
    #
    # @example
    #   class User < ActiveRecord::Base
    #     class << self
    #       wrap_in_trx def find_or_create(name)
    #         user = find_by(name: name)
    #         user ||= create(name: name, title: 'Default')
    #         user
    #       end
    #     end
    #   end
    #
    #   User.find_or_create('some name')
    #   #   (0.6ms)  BEGIN
    #   #   User Load (0.4ms)  SELECT "users".* FROM "users" WHERE "users"."name" = $1 LIMIT 1  [["name", 'some name']]
    #   #   User Create (1.8 ms) INSERT INTO "users" ("name", "title") VALUES ($1, $2) RETURNING "id"  [["name", "some name"], ["title", "Default"]]
    #   #   (0.2ms)  COMMIT
    #
    # @param method [Symbol] a name of the method
    # @param class_name [String, nil] pass an ActiveRecord model class name to define the appropriate connection of the
    #   transaction
    # @return [Symbol]
    def wrap_in_trx(method, class_name = nil)
      module_to_prepend = Module.new do
        define_method(method) do |*args, **kwargs, &blk|
          context = class_name&.constantize || self
          context.trx do
            super(*args, **kwargs, &blk)
          end
        end
      end
      prepend module_to_prepend
      method
    end

    # A shorthand version of <tt>ActiveRecord::Base.transaction</tt>
    def trx(...)
      return transaction(...) if respond_to?(:transaction)

      ActiveRecord::Base.transaction(...)
    end
  end
end
