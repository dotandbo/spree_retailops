module Spree
  module Retailops
    class RopOrderHelper
      attr_accessor :order, :options

      def standard_shipping_label
        'Standard Shipping'
      end

      # There is a major impedence mismatch between Spree and RetailOps on the subject of ship pricing.  Spree assigns a ship price (which confusingly is called
      # a "shipment cost") to each shipment/package, while RetailOps supports shipping lines at the order and ordered-item level.
      #
      # When an order is being actively managed by the RetailOps integration, we want a consistent price between systems, so when an order is managed we combine
      # all of the shipment prices into a single price which is used on the RetailOps side and also stashed on the order, either as a global adjustment
      # (matching historical spree_retailops behavior, and arguably more correct for multi-shipment orders) or as the price on one of the shipments (arguably
      # more correct for single-shipment orders).
      def separate_shipment_costs
        changed = false
        return false if @order.canceled?
        extracted_total = 0.to_d
        @order.shipments.each do |shipment|
          # Spree 2.1.x: shipment costs are expressed as order adjustments linked through source to the shipment
          # Spree 2.2.x: shipments have a cost which is authoritative, and one or more adjustments (shiptax, etc)
          cost = if shipment.respond_to?(:adjustment)
            shipment.adjustment.try(:amount) || 0.to_d
          else
            shipment.cost + shipment.adjustment_total
          end

          extracted_total += cost if cost > 0
        end

        order_ship_adj = @order.adjustments.where(label: standard_shipping_label).first
        extracted_total += order_ship_adj.amount if order_ship_adj

        return apply_shipment_price(extracted_total)
      end

      # 2015-02-27: Transforming shipments to an advisory shipping method turns out to be a bad idea because that loses the information about what the original
      # shipping method was, and we need that information in order to recalculate the shipping price for new/removed items in the new 'delegated' mode.  So
      # instead, keep the existing shipment method, but set the adjustment to 0 and close it.
      def apply_shipment_price(price)
        changed = false
        return false if @order.canceled?

        target_ship = nil

        if Spree::Config[:retailops_express_shipping_price] != "adjustment"
          target_ship = @order.shipments.unshipped.first || @order.shipments.first
        end

        @order.shipments.each do |shipment|
          this_ship_price = 0
          if shipment == target_ship
            this_ship_price = price
            price = 0 # do not need adjustment
          end

          rate = shipment.selected_shipping_rate
          unless shipment.selected_shipping_rate
            # probably shouldn't happen
            shipment.add_shipping_method(rop_tbd_method, true)
            rate = shipment.selected_shipping_rate
            changed = true
          end

          if shipment.respond_to?(:adjustment_total) && shipment.adjustment_total > 0
            shipment.adjustments.delete_all
          end

          if rate.cost != this_ship_price
            changed = true
            rate.cost = this_ship_price

            if shipment.respond_to?(:adjustment)
              shipment.ensure_correct_adjustment

              # Override and lock the shipment adjustment so that normal Spree rules won't apply to change it
              adj = shipment.adjustment
              adj.amount = this_ship_price
              adj.close if adj.open?
            end
            # otherwise setting the shipping rate was enough.  Can't actually close a shipping rate but hopefully those won't be recalculated too often
            shipment.save!
          end
        end

        order_ship_adj = @order.adjustments.where(label: standard_shipping_label).first
        if price > 0 && !order_ship_adj
          @order.adjustments.create(amount: price, label: standard_shipping_label, mandatory: false)
          @order.save!
          changed = true
        elsif order_ship_adj && order_ship_adj.amount != price
          order_ship_price.amount = price
          @order.save!
          changed = true
        end
      end

      def rop_tbd_method
        advisory_method(options["partial_ship_name"] || "Unshipped")
      end

      # Find or create an advisory (not selectable) shipping method to represent how ROP shipped this item
      def advisory_method(name)
        use_any_method = options["use_any_method"]
        @advisory_methods ||= {}
        unless @advisory_methods[name]
          @advisory_methods[name] = ShippingMethod.where(admin_name: name).detect { |s| use_any_method || s.calculator.is_a?(Spree::Calculator::Shipping::RetailopsAdvisory) }
        end

        unless @advisory_methods[name]
          raise "Advisory shipping method #{name} does not exist and automatic creation is disabled" if options["no_auto_shipping_methods"]
          @advisory_methods[name] = ShippingMethod.create!(name: name, admin_name: name) do |m|
            m.calculator = Spree::Calculator::Shipping::RetailopsAdvisory.new
            m.shipping_categories << ShippingCategory.first
          end
        end
        @advisory_methods[name]
      end
    end
  end
end
