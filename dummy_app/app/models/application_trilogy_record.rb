# frozen_string_literal: true

class ApplicationTrilogyRecord < ActiveRecord::Base
  self.abstract_class = true

  connects_to database: { writing: :primary_trilogy, reading: :primary_trilogy }
end
