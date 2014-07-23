module Spree
  module Retailops
    class RopStockHelper
      def apply_stock variant, stock_hash, detailed
        @locations ||= {}
        current = {}

        variant.stock_items.each do |si|
          @locations[si.stock_location.name] ||= si.stock_location
          current[si.stock_location] = { stock_item: si, on_hand: si.count_on_hand, backorderable: si.backorderable }
        end

        stock_hash.each do |locname, qty|
          locname = locname.to_s
          location = @locations[locname] ||= StockLocation.find_or_create_by!(name: locname) { |l| l.admin_name = locname }

          old = current.delete(location) || { on_hand: 0, backorderable: false }
          new = { on_hand: qty, backorderable: detailed["backorder"][locname] ? true : false }

          stock_item = old[:stock_item] || location.stock_item_or_create(variant)

          stock_item.stock_movements.create!(quantity: new[:on_hand] - old[:on_hand]) if new[:on_hand] != old[:on_hand]
          stock_item.update!(backorderable: new[:backorderable]) if new[:backorderable] != old[:backorderable]
        end

        # zero out unmentioned locations
        # unsure if this should mention backorder
        current.each do |old_loc, old|
          old_loc.move variant, -old[:on_hand] if old[:on_hand] != 0
        end

        if detailed && variant.respond_to?(:retailops_notify_inventory)
          variant.retailops_notify_inventory(detailed)
        end
      end
    end
  end
end
