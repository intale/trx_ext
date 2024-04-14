# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in trx_ext.gemspec
gemspec

if ENV['AR_VERSION']
  # Given ENV['AR_VERSION'] to equal "6.0" will produce
  # ```ruby
  # gem 'activerecord', "~> 6.0", "< 6.1"
  # ```
  gem 'rails', "~> #{ENV['AR_VERSION']}", "< #{ENV['AR_VERSION'].next}"
else
  gem 'rails'
end

gem "rake", "~> 13.0"
gem 'rspec', '~> 3.12'
gem 'timecop', '~> 0.9.8'
# To support postgresql adapter
gem 'pg', '~> 1.5', '>= 1.5.4'
# To support sqlite3 adapter
gem 'sqlite3', '~> 1.7', '>= 1.7.1'
# To support mysql2 adapter
gem 'mysql2', '~> 0.5.5'
# To support trilogy adapter
gem 'trilogy', '~> 2.8'
gem 'factory_bot_rails', '~> 6.4', '>= 6.4.3'
gem 'fivemat', '~> 1.3', '>= 1.3.7'
gem 'rspec-its', '~> 1.3'
gem "bootsnap", require: false
gem 'rspec-rails',  '~> 6.0'
