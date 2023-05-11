# frozen_string_literal: true

require 'erb'

class Config
  DB_CONFIG_FILE = File.expand_path('config/database.yml', __dir__)

  class << self
    # @return [nil, Hash]
    def db_config
      @db_config ||=
        begin
          return unless File.exist?(DB_CONFIG_FILE)

          YAML.load(ERB.new(File.read(DB_CONFIG_FILE)).result)
        end
    end
  end
end
