# frozen_string_literal: true

FactoryBot.define do
  factory :dummy_pg_record do
    name { 'a name' }
    sequence(:unique_name) { |n| "unique name #{n}" }
  end

  factory :dummy_sqlite_record do
    name { 'a name' }
    sequence(:unique_name) { |n| "unique name #{n}" }
  end

  factory :dummy_mysql_record do
    name { 'a name' }
    sequence(:unique_name) { |n| "unique name #{n}" }
  end
end
