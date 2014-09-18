module Spree
  module Api
    module Retailops
      class OrdersController < Spree::Api::BaseController
        # This function handles fetching order data for RetailOps.  In the spirit of
        # pushing as much maintainance burden as possible onto RetailOps and not
        # requiring different versions per client, we return data in a fairly raw
        # state.  This also needs to be relatively fast.  Since we cannot guarantee
        # that the other side will receive and correctly process the data we return
        # (there might be a badly timed network dropout, or *gasp* a bug), we don't
        # mark orders as exported here - that's handled in export below.

        module Extractor
          INCLUDE_BLOCKS = {}
          LOOKUP_LISTS = {}

          def self.use_association(klass, syms, included = true)
            syms.each do |sym|
              to_assoc = klass.reflect_on_association(sym) or next
              to_incl_block = to_assoc.polymorphic? ? {} : (INCLUDE_BLOCKS[to_assoc.klass] ||= {})
              incl_block = INCLUDE_BLOCKS[klass] ||= {}
              incl_block[sym] = to_incl_block
              (LOOKUP_LISTS[klass] ||= {})[sym] = true if included
            end
          end

          def self.ad_hoc(klass, sym, need = [])
            use_association klass, need, false
            (LOOKUP_LISTS[klass] ||= {})[sym] = Proc.new
          end

          use_association Order, [:line_items, :adjustments, :shipments, :ship_address, :bill_address, :payments]

          use_association LineItem, [:adjustments]
          ad_hoc(LineItem, :sku, [:variant]) { |i| i.variant.try(:sku) }
          ad_hoc(LineItem, :advisory, [:variant]) { |i| p = i.variant.try(:product); i.try(:retailops_is_advisory?) || p.try(:retailops_is_advisory?) || p.try(:is_gift_card) }

          use_association Variant, [:product], false

          use_association Shipment, [:adjustments]
          ad_hoc(Shipment, :shipping_method_name, [:shipping_rates]) { |s| s.shipping_method.try(:name) }

          use_association ShippingRate, [:shipping_method], false

          ad_hoc(Address, :state_text, [:state]) { |a| a.state_text }
          ad_hoc(Address, :country_iso, [:country]) { |a| a.country.try(:iso) }

          use_association Payment, [:source]
          ad_hoc(Payment, :method_class, [:payment_method]) { |p| p.payment_method.try(:type) }

          def self.walk_order_obj(o)
            ret = {}
            o.class.column_names.each { |cn| ret[cn] = o.public_send(cn).as_json }
            if list = LOOKUP_LISTS[o.class]
              list.each do |sym, block|
                if block.is_a? Proc
                  ret[sym.to_s] = block.call(o)
                else
                  relat = o.public_send(sym)
                  if relat.is_a? ActiveRecord::Relation
                    relat = relat.map { |rec| walk_order_obj rec }
                  elsif relat.is_a? ActiveRecord::Base
                    relat = walk_order_obj relat
                  end
                  ret[sym.to_s] = relat
                end
              end
            end
            return ret
          end

          def self.root_includes
            INCLUDE_BLOCKS[Order] || {}
          end
        end

        def index
          authorize! :read, [Order, LineItem, Variant, Payment, PaymentMethod, CreditCard, Shipment, Adjustment]

          options = params['options'] || {}
          query = options['filter'] || {}
          query['completed_at_not_null'] ||= 1
          query['retailops_import_eq'] ||= 'yes'
          results = Order.ransack(query).result.limit(params['limit'] || 50).includes(Extractor.root_includes)

          render text: results.map { |o|
            begin
              Extractor.walk_order_obj(o)
            rescue Exception => ex
              { "error" => ex.to_s, "trace" => ex.backtrace, "number" => o.number }
            end
          }.to_json
        end

        def export
          authorize! :update, Order
          ids = params["ids"]
          raise "ids must be a list of numbers" unless ids.is_a?(Array) && ids.all? { |i| i.is_a? Fixnum }

          missing_ids = ids - Order.where(id: ids, retailops_import: ['done', 'yes']).pluck(:id)
          raise "order IDs could not be matched or marked nonimportable: " + missing_ids.join(', ') if missing_ids.any?

          Order.where(retailops_import: 'yes', id: ids).update_all(retailops_import: 'done')
          render text: {}.to_json
        end

        def synchronize
          authorize! :update, Order
          changed = false
          result = []
          order = Order.find_by!(number: params["order_refnum"].to_s)
          ActiveRecord::Base.transaction do

            # RetailOps will be sending in an authoritative (potentially updated) list of line items
            # We make our data match that as well as possible, and then send the list back annotated with channel_refnums and quantities/costs/etc

            used_v = {}

            params["line_items"].to_a.each do |lirec|
              corr = lirec["corr"].to_s
              sku  = lirec["sku"].to_s
              qty  = lirec["quantity"].to_i
              eshp = Time.at(lirec["estimated_ship_date"].to_i)
              cost = BigDecimal.new(lirec["estimated_cost"].to_f, 2)
              extra = lirec["ext"] || {}

              variant = Spree::Variant.find_by(sku: sku)
              next unless variant
              next if qty <= 0
              next if used_v[variant]
              used_v[variant] = true

              li = order.find_line_item_by_variant(variant)
              oldqty = li ? li.quantity : 0

              next if !li && qty == oldqty # should be caught by <= 0

              if qty > oldqty
                changed = true
                # make sure the shipment that will be used, exists
                # expanded for 2.1.x compat
                shipment = order.shipments.detect do |shipment|
                  (shipment.ready? || shipment.pending?) && shipment.include?(variant)
                end

                shipment ||= order.shipments.detect do |shipment|
                  (shipment.ready? || shipment.pending?) && variant.stock_location_ids.include?(shipment.stock_location_id)
                end

                unless shipment
                  shipment = order.shipments.build
                  shipment.state = 'ready'
                  shipment.stock_location_id = variant.stock_location_ids[0]
                  shipment.save!
                end

                li = order.contents.add(variant, qty - oldqty, nil, shipment)
              elsif qty < oldqty
                changed = true
                li = order.contents.remove(variant, oldqty - qty)
              end

              if li.cost_price != cost
                changed = true
                li.update!(cost_price: cost)
              end

              if li.respond_to?(:estimated_ship_date=) && li.estimated_ship_date != eshp
                changed = true
                li.update!(estimated_ship_date: eshp)
              end

              if li.respond_to?(:retailops_set_estimated_ship_date)
                changed = true if li.retailops_set_estimated_ship_date(eshp)
              end

              if li.respond_to?(:retailops_extension_writeback)
                changed = true if li.retailops_extension_writeback(extra)
              end

              result << { corr: corr, refnum: li.id, quantity: li.quantity }
            end

            order.line_items.each do |li|
              next if used_v[li.variant]
              order.contents.remove(li.variant, li.quantity)
              changed = true
            end
          end

          render text: {
            changed: changed,
            dump: Extractor.walk_order_obj(order),
            result: result,
          }.to_json
        end
      end
    end
  end
end
