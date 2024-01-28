# frozen_string_literal: true

FactoryBot.define do
  factory :dummy_pg_record, class: 'DummyPgRecord' do
    name { 'a name' }
    sequence(:unique_name) { |n| "unique name #{n}" }
  end

  factory :dummy_sqlite_record, class: 'DummySqliteRecord' do
    name { 'a name' }
    sequence(:unique_name) { |n| "unique name #{n}" }
  end
end
