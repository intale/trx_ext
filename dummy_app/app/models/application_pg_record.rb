# frozen_string_literal: true

class ApplicationPgRecord < ActiveRecord::Base
  self.abstract_class = true

  connects_to database: { writing: :primary_pg, reading: :primary_pg }
end
