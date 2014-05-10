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

        # XXX pretty sure there's a better approach in ruby syntax for this
        class Extractor
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

        # TODO: change this to use Ransack so ROP can drive the selection process
        # (this is subtly wrong as is, we want to import orders with pending payments)
        def index
          authorize! :read, [Order, LineItem, Variant, Payment, PaymentMethod, CreditCard, Shipment, Adjustment]

          query = params['all'] ? {} : { shipment_state: 'ready', payment_state: 'paid', retailops_import: 'yes' }

          if params['completed_from'] || params['completed_to']
            query[:completed_at] = (Time.parse(params['completed_from']) rescue Time.mktime(1970)) ..
              (Time.parse(params['completed_to']) rescue Time.now.next_year)
          end

          result = Order.where(query).limit(params[:limit] || 50).includes(Extractor.root_includes).map { |o| Extractor.walk_order_obj(o) }
          render text: result.to_json
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

        # "Settlement" subsystem - called by ROP when there are large changes in the status of the order.
        #
        # * First we add zero or more "packages" of things we were able to ship.
        #
        # * Then we flag the order as complete - this means ROP will not be shipping any more.  Often everything will have been shipped.  Sometimes not.  Oversells and short ships are af will add a negative
        #   adjustment if the order was short shipped.  Depending on
        #   configuration this may also cause automatic capturing or refunding of
        #   payments.
        #
        # * Then (later, and hopefully not at all) we can add refunds for
        #   inventory returned in ROP.

        # Package adding: This reflects a fairly major impedence mismatch
        # between ROP and Spree, insofar as Spree wants to create shipments at
        # checkout time and charge exact shipping, while ROP standard practice
        # is to charge an abstraction of shipping that's close enough on
        # average, and then decide the details of how this order will be
        # shipped when it's actually ready to go out the door.  Because of this
        # we have to fudge stuff a bit on shipment and recreate the Spree
        # shipments to reflect how ROP is actually shipping it, so that the
        # customer has the most actionable information.  A complication is that
        # Spree's shipping rates are tied to the shipment, and need to be
        # converted into order adjustments before we start mangling the
        # shipments.  Credit where due: this code is heavily inspired by some
        # code written by @schwartzdev for @dotandbo to handle an Ordoro
        # integration.
        def add_package
          ActiveRecord::Base.transaction do
            find_order
            separate_shipment_costs
            extract_items_into_package
          end
          render text: {}.to_json
        end

        # The Spree core appears to reflect two schools of thought on
        # refunding.  The user guide suggests that one reason you might edit
        # orders is if you could not ship them, which suggests handling short
        # ships by modifying the order itself, then refunding by the difference
        # between the new order value and the payment.  The core code itself
        # handles returns by creating an Adjustment for the returned
        # merchandise, and leaving the line items alone.
        #
        # We follow the latter approach because it allows us to keep RetailOps
        # as the sole authoritative source of refund values, avoiding useless
        # mismatch warnings.
        def mark_complete
          ActiveRecord::Base.transaction do
            find_order
            separate_shipment_costs
            create_short_adjustment
            delete_unshipped_shipments
          end
          settle_payments_if_desired
          render text: @settlement_results.to_json
        end

        def add_refund
          ActiveRecord::Base.transaction do
            find_order
            create_refund_adjustment
          end
          settle_payments_if_desired
          render text: @settlement_results.to_json
        end

        private
          # What order is being settled?
          def find_order
            @order = Order.find_by!(number: params["order_refnum"].to_s)
            authorize! :update, @order
          end

          # To prevent Spree from trying to recalculate shipment costs as we
          # create and delete shipments, transfer shipping costs to order
          # adjustments
          def separate_shipment_costs
            extracted_total = 0
            @order.shipments.each do |shipment|
              # Spree 2.1.x: shipment costs are expressed as order adjustments linked through source to the shipment
              # Spree 2.2.x: shipments have a cost which is authoritative, and one or more adjustments (shiptax, etc)
              cost = if shipment.respond_to?(:adjustment)
                shipment.adjustment.present? ? shipment.adjustment.amount : 0
              else
                shipment.cost + shipment.adjustment_total
              end

              if cost > 0
                extracted_total += cost
                shipment.adjustment.open if shipment.respond_to? :adjustment
                shipment.adjustments.delete_all if shipment.respond_to? :adjustments
                shipment.shipping_rates.delete_all
                shipment.add_shipping_method(rop_tbd_method, true)
                shipment.save!
              end
            end

            if extracted_total > 0
              # TODO: is Standard Shipping the best name for this?  Should i18n happen?
              @order.adjustments.create(amount: extracted_total, label: "Standard Shipping", mandatory: false)
              @order.save!
            end
          end

          def extract_items_into_package
            raise "Not implemented"
          end

          def create_short_adjustment
            raise "Not implemented"
          end

          def delete_unshipped_shipments
            raise "Not implemented"
          end

          def create_refund_adjustment
            raise "Not implemented"
          end

          def settle_payments_if_desired
            raise "Not implemented"
            # while params["ok_capture"] && @order.needs_money && op = @order.payments.detect { |opp| can be captured && value <= @order.money_needed }
            #   op.capture
            # end
            # while params["ok_partial_capture"] && @order.needs_money && op = @order.payments.detect { |op| can be partially captured && value > @order.money_needed }
            #   op.capture partially
            # end
            # while params["ok_void"] && @order.fully_paid_for && op = @order.payments.detect { can be voided }
            #   op.void
            # end
            # while params["ok_refund"] && @order.overpaid && op = @order.payments.detect { can be refunded }
            #   op.refund just enough
            # end
          end

          def rop_tbd_method
            @tbd_shipping_method ||= raise "Not implemented"
          end
      end
    end
  end
end
