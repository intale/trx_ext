# frozen_string_literal: true

require_relative "boot"

require "rails"

%w(
  active_record/railtie
  action_controller/railtie
  action_view/railtie
).each do |railtie|
  begin
    require railtie
  rescue LoadError
  end
end


# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module DummyApp
  class Application < Rails::Application
    rails_version = Gem::Specification.find_by_name('rails').version
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults rails_version.segments[0..1].join('.')

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")

    # Only loads a smaller set of middleware suitable for API only apps.
    # Middleware like session, flash, cookies can be added back manually.
    # Skip views, helpers and assets when generating a new resource.
    config.api_only = true
    if rails_version < Gem::Version.new('7.0.0')
      config.active_record.legacy_connection_handling = false
    end
    # config.active_job.queue_adapter = :async


    if defined?(FactoryBotRails)
      config.factory_bot.definition_file_paths += [File.expand_path('../../spec/factories', __dir__)]
    end
  end
end
