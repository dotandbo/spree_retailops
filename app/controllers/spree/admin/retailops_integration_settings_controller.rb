module Spree
  module Admin
    class RetailopsIntegrationSettingsController < Spree::Admin::BaseController

      def update
        Spree::Config.set(params[:preferences])

        redirect_to edit_admin_retailops_integration_settings_path
      end
    end
  end
end
