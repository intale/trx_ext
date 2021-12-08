# frozen_string_literal: true

module TrxExt
  class Config
    attr_accessor :unique_retries

    def initialize
      # Number of retries of unique constraint error before failing
      @unique_retries = 5
    end
  end
end
