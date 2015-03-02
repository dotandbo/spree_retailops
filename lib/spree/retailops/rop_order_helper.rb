module Spree
  module Retailops
    class RopOrderHelper
      attr_accessor :order, :options

      # To prevent Spree from trying to recalculate shipment costs as we
      # create and delete shipments, transfer shipping costs to order
      # adjustments
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

          if cost > 0
            extracted_total += cost
            shipment.adjustment.open if shipment.respond_to? :adjustment
            shipment.adjustments.delete_all if shipment.respond_to? :adjustments
            shipment.shipping_rates.delete_all
            shipment.cost = 0
            shipment.add_shipping_method(rop_tbd_method, true)
            shipment.save!
            changed = true
          end
        end

        if extracted_total > 0
          # TODO: is Standard Shipping the best name for this?  Should i18n happen?
          @order.adjustments.create(amount: extracted_total, label: "Standard Shipping", mandatory: false)
          @order.save!
          changed = true
        end

        return changed
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

        order_ship_adj = @order.adjustments.where(label: 'Standard Shipping')
        if price > 0 && !order_ship_adj
          @order.adjustments.create(amount: price, label: "Standard Shipping", mandatory: false)
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
