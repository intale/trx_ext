# frozen_string_literal: true

# Dummy record. It is used to test transaction integration.
class DummyMysqlRecord < ApplicationMysqlRecord
  class << self
    def find_or_create_by(attributes, &block)
      find_by(attributes) || create(attributes, &block)
    end
    wrap_in_trx :find_or_create_by
  end
end
