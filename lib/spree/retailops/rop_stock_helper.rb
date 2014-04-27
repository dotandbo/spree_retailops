module Spree
  module Retailops
    class RopStockHelper
      def apply_stock variant, stock_hash
        @locations ||= {}
        current = {}

        variant.stock_items.each do |si|
          current[si.stock_location] = si.count_on_hand if si.count_on_hand != 0
        end

        stock_hash.each do |locname, qty|
          locname = locname.to_s
          location = @locations[locname] ||= StockLocation.find_or_create_by!(name: locname) { |l| l.admin_name = locname }

          location.move variant, qty.to_i() - (current.delete(location) || 0)
        end

        # zero out unmentioned locations
        current.each { |old_loc, old_qty| old_loc.move variant, -old_qty }
      end
    end
  end
end
