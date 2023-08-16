# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in trx_ext.gemspec
gemspec

gem "rake", "~> 13.0"

if ENV['AR_VERSION']
  gem 'activerecord', *ENV['AR_VERSION'].split(',')
end
