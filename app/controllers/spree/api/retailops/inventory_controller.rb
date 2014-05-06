module Spree
  module Api
    module Retailops
      # This module receives inventory updates from RetailOps in the form of a JSON document and applies them to your Spree database.
      #
      # {
      #     "inventory_data": [
      #         {
      #             "sku":"ASDF",
      #             "stock":{"loc1":11,"loc2":5}
      #         }
      #     ]
      # }
      #
      # Much simpler than catalog sync (and intended to be faster).  Note that
      # the SKU need not exist, and inventory updates will be silently ignored if
      # the SKU does not exist.  This is because when a product is received, one
      # or more catalog and inventory updates are generated, which race, and we
      # may receive the inventory update before the catalog task has created our
      # variant.  Since the catalog process also updates inventory, it's harmless
      # to just ignore this.

      class InventoryController < Spree::Api::BaseController
        def inventory_push
          authorize! :create, StockLocation
          authorize! :create, StockItem
          authorize! :update, StockItem

          stocker = RopStockHelper.new

          ActiveRecord::Base.transaction do
            type_check(params, "inventory_data", Array).each do |ivd|
              sku = type_check(ivd, "sku", String)
              stock = type_check(ivd, "stock", Hash)

              variant = Variant.find_by(sku: sku) or next
              # Totally OK if the variant doesn't exist, due to races - inventory may be processed first, we'll redo the inventory on catalog push
              stocker.apply_stock variant, stock
            end
          end

          render text: { }.to_json
        end

        private
          def type_check h, key, type
            val = h[key]
            raise "#{key} must be #{type.name}" unless val.kind_of? type
            val
          end
      end
    end
  end
end
