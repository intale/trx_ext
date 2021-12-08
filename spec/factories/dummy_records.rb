# frozen_string_literal: true

FactoryBot.define do
  factory :dummy_record do
    name { 'a name' }
    sequence(:unique_name) { |n| "unique name #{n}" }
  end
end
