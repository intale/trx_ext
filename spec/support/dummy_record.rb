# frozen_string_literal: true

# Dummy record. It is used to test transaction integration.
class DummyRecord < ActiveRecord::Base
  class << self
    wrap_in_trx :find_or_create_by

    def setup
      migration = ActiveRecord::Migration.new
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
