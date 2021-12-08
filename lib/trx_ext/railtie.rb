# frozen_string_literal: true

module TrxExt
  class Railtie < Rails::Railtie
    initializer 'trx_ext.setup_ar' do
      TrxExt.integrate!
    end
  end
end
