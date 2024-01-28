# frozen_string_literal: true

class ApplicationSqliteRecord < ActiveRecord::Base
  self.abstract_class = true

  connects_to database: { writing: :primary_sqlite, reading: :primary_sqlite }
end
