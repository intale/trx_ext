# frozen_string_literal: true

class ApplicationMysqlRecord < ActiveRecord::Base
  self.abstract_class = true

  connects_to database: { writing: :primary_mysql, reading: :primary_mysql }
end
