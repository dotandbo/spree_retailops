module Spree
  module Retailops
    # This module receives catalog updates from RetailOps in the form of a JSON document and applies them to your Spree database.
    #
    # {
    #     "products": [
    #         {
    #             "sku":"ASDF",
    #             ...more properties, all optional except for sku and options...
    #             "options":["Size","Color"],
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
      def catalog_push
        # actually a lot more privs maybe?
        authorize! :create, Product
        authorize! :update, Product

        params["products"].isa? Array or throw "products must be array"

        @diag = []
        params["products"].each { |p| upsert_product p }

        render json: { "import_results" => @diag }
      end

      private
        def add_error(msg)
          @diag << { "corr_id" => @current_corr_id, "message" => msg, "failed" => true }
        end

        def add_warn(msg)
          @diag << { "corr_id" => @current_corr_id, "message" => msg }
        end

        def validate_to_error(rec)
          rec.errors.to_a.each { |m| add_error(m) }
        end

        def update_if(hash,key)
          yield hash[key] if hash.has_key? key
        end

        def upsert_product(p)
          @current_corr_id = p["corr_id"]

          return add_error("no variants specified") if p["variants"].empty?
          # in the non-varying case, copy data up
          if p["options"].empty?
            v = p["variants"][0]
            p["variants"] = []
            %w( images tax_category weight height depth width cost_price price cost_currency sku ).each do |c|
              p[c] = v[c] if v.has_key?(c)
            end
          end

          return add_error("sku not specified") if p["sku"].empty?

          # Try to use the existing SKU to pull up a product
          ex_master_variant = Variant.includes(:product).find_by(sku: p["sku"], is_master: true, deleted_at: nil)
          product = ex_master_variant && ex_master_variant.product

          # no product?  OK then
          product ||= Product.new

          # Update product attributes
          update_if p, "tax_category" { |cat| product.tax_category = cat.empty? ? nil : TaxCategory.find_or_create_by!(name: cat) }
          update_if p, "available_on" { |when| product.available_on = when.nil? ? nil : Time.at(when) }
          update_if p, "slug" { |slug| product.slug = slug }
          update_if p, "meta_description" { |md| product.meta_description = md }
          update_if p, "meta_keywords" { |mk| product.meta_keywords = mk }
          update_if p, "shipping_category" { |sc| product.shipping_category = sc.empty? ? nil : ShippingCategory.find_or_create_by!(name: sc) }

          update_if p, "options_used" do |opts|
            product.product_option_types.destroy_all
            opts.each do |opt|
              
            end
          end

          update_if p, "taxa" do |taxa|
            
          end

          product.save or return validate_to_error(product)

          # Create/update variants, including the master
          upsert_variant(product, product.master_variant, p)

          p["variants"].each { |v| upsert_variant(product, nil, v) }
        end

        def upsert_variant(product, variant, v)
          @current_corr_id = v["corr_id"]

          return add_error("no sku specified") if v["sku"].empty?

          unless variant
            variant = Variant.find_by(sku: v["sku"], is_master: false, deleted_at: nil)
            if variant && variant.product_id != product.id
              # Oops.  Need to steal the SKU
              # Should we delete here?
              variant.sku = nil
              variant.save!
              variant = nil
            end

            unless variant
              # need to create a brand new variant
              variant = product.variants.new(sku: v["sku"])
            end
          end

          # Set variant aspects
          update_if v, "tax_category" { |tc| variant.tax_category = tc.empty? ? nil : TaxCategory.find_or_create_by!(name: tc) }
          update_if v, "cost_currency" { |cc| variant.cost_currency = cc }
          update_if v, "weight" { |w| variant.weight = w.to_f }
          update_if v, "width" { |w| variant.width = w.to_f }
          update_if v, "height" { |w| variant.height = w.to_f }
          update_if v, "depth" { |w| variant.depth = w.to_f }
          update_if v, "cost_price" { |w| variant.cost_price = w.to_f }

          update_if v, "options" do |op|
            variant.option_values.destroy_all # TODO: optimize
            op.each do |kv|
              variant.set_option_value kv["key"], kv["value"] if !kv["key"].blank? && !kv["value"].blank?
            end
          end

          update_if v, "images" do |img|
            # TODO
          end

          variant.save or return validate_to_error(variant)
        end
    end
  end
end
