# frozen_string_literal: true

unless defined?(ActiveRecord::DatabaseAlreadyExists) # rails 6.0 doesn't have this constant
  require 'pg'
  ActiveRecord::DatabaseAlreadyExists = PG::DuplicateDatabase
end

# Dummy record. It is used to test transaction integration.
class DummyRecord < ActiveRecord::Base
  class << self
    wrap_in_trx :find_or_create_by

    def setup
      migration = ActiveRecord::Migration.new
      ActiveRecord::Base.establish_connection(Config.db_config.merge('database' => 'postgres'))
      migration.create_database(Config.db_config['database'], encoding: 'utf-8') rescue ActiveRecord::DatabaseAlreadyExists
      ActiveRecord::Base.establish_connection(Config.db_config)

      if table_exists?
        if columns.map(&:name) != %w(id name unique_name created_at)
          migration.drop_table(:dummy_records)
          setup
        end
      else
        migration.create_table(:dummy_records) do |t|
          t.string :name
          t.string :unique_name
          t.datetime :created_at
        end
        migration.add_index :dummy_records, :unique_name, unique: true
      end
    end
  end
end
