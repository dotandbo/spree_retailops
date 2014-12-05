module Spree
  module Api
    module Retailops
      # This module receives catalog updates from RetailOps in the form of a JSON document and applies them to your Spree database.
      #
      # {
      #     "products": [
      #         {
      #             "sku":"ASDF",
      #             ...more properties, all optional except for sku and varies...
      #             "varies":true,
      #             "variants":[
      #                 { "sku":"ASDF-1", ... }
      #             ]
      #         }
      #     ]
      # }
      #
      # One important subtlety here is that RetailOps will always send one or
      # more variants, even in the degenerate case where there are no options.
      # We do a transformation here if there are no options, making the variant
      # data go to the master variant.
      #
      # The catalog_push method returns a list of errors which are associated
      # with specific objects, for RetailOps to display as feed errors.  We track
      # the current object using a correlation ID so that add_error and add_warn
      # can associate errors with the correct thing.

      class CatalogController < Spree::Api::BaseController
        include CatalogHelpers

        def catalog_push
          # actually a lot more privs maybe?
          authorize! :create, Product
          authorize! :update, Product

          products = if params["products_json"]
            # Workaround for https://github.com/rails/rails/issues/8832
            JSON.parse(params["products_json"])
          else
            params["products"]
          end

          @diag = []
          @memo = {}
          @failed = {}

          Spree::Retailops::CatalogJob.perform_later(products, params)

          render text: { "import_results" => @diag }.to_json
        end
      end
    end
  end
end
