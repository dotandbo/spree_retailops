module Spree
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
      def catalog_push
        # actually a lot more privs maybe?
        authorize! :create, Product
        authorize! :update, Product

        params["products"].is_a? Array or throw "products must be array"

        @diag = []
        @memo = {}
        ActiveRecord::Base.transaction do
          params["products"].each { |pd| upsert_product pd }
        end

        render json: { "import_results" => @diag }
      rescue => exn
        print exn, "\n", exn.backtrace.join("\n"), "\n"
        raise
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

        def memo(*args)
          return (@memo[args] ||= [block_given? ? yield : send(*args)])[0]
        end

        def upsert_tax_category(cat)
          return cat.empty? ? nil : TaxCategory.find_or_create_by!(name: cat)
        end

        def upsert_ship_category(sc)
          return sc.empty? ? nil : ShippingCategory.find_or_create_by!(name: sc)
        end

        def upsert_option_type(opt)
          return opt.blank? ? nil : OptionType.find_or_create_by!(name: opt) { |o| o.presentation = opt }
        end

        def upsert_option_value(type, value)
          return nil if value.blank?
          return type.option_values.find_or_create_by!(name: value) { |v| v.presentation = value }
        end

        def upsert_taxon_path(path)
          taxonomy_name, *taxon_names = *path
          taxonomy = memo :upsert_taxonomy, taxonomy_name do
            Taxonomy.find_or_create_by!(name: taxonomy_name)
          end

          taxon = nil

          taxon_names.each do |taxon_name|
            taxon = memo :upsert_taxon, (taxon && taxon.id), taxon_name do
              taxonomy.taxons.find_or_create_by!(name: taxon_name)
            end
          end

          return taxon
        end

        def upsert_product(pd)
          @current_corr_id = pd["corr_id"]

          return add_error("no variants specified") if pd["variants"].empty?
          # in the non-varying case, copy data up
          if !pd["varies"]
            v = pd["variants"][0]
            pd["variants"] = []
            %w( images tax_category weight height depth width cost_price price cost_currency sku ).each do |c|
              pd[c] = v[c] if v.has_key?(c)
            end
          end

          return add_error("sku not specified") if pd["sku"].empty?

          # Try to use the existing SKU to pull up a product
          ex_master_variant = Variant.includes(:product).find_by(sku: pd["sku"], is_master: true, deleted_at: nil)
          product = ex_master_variant && ex_master_variant.product

          p pd["sku"], ex_master_variant, product

          # no product?  OK then
          product ||= Product.new

          # Update product attributes
          update_if(pd, "tax_category") { |cat| product.tax_category = memo(:upsert_tax_category, cat) }
          update_if(pd, "available_on") { |avtime| product.available_on = avtime.nil? ? nil : Time.at(avtime) }
          update_if(pd, "slug") { |slug| product.slug = slug }
          update_if(pd, "name") { |name| product.name = name }
          update_if(pd, "meta_description") { |md| product.meta_description = md }
          update_if(pd, "meta_keywords") { |mk| product.meta_keywords = mk }
          update_if(pd, "ship_category") { |sc| product.shipping_category = memo(:upsert_ship_category, sc) }

          # set things that hang off the product
          update_if pd, "options_used" do |opts|
            product.option_types = pd["options_used"].map { |opt| memo(:upsert_option_type, opt) }
          end

          update_if pd, "taxa" do |taxa|
            product.taxons = pd["taxa"].map { |path| upsert_taxon_path(path) }
          end

          update_if pd, "properties" do |prop|
            prop.each do |kv|
              #this does not erase properties ever, nor overwrite properties not mentioned
              #both of these are by design-ish
              next if kv["key"].blank?
              old_value = product.property(kv["key"])
              next if old_value == kv["value"] || old_value.nil? && kv["value"].blank?
              product.set_property(kv["key"], kv["value"])
            end
          end

          # Create/update variants, including the master
          upsert_variant(product, product.master, pd)

          # product itself A-OK?  if not fail
          product.save or return validate_to_error(product)

          pd["variants"].each { |v| upsert_variant(product, nil, v) }
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
          else
            variant.sku = v["sku"]
          end

          # Set variant aspects
          update_if(v, "price") { |p| variant.price = p.to_f }
          update_if(v, "tax_category") { |tc| variant.tax_category = memo(:upsert_tax_category, tc) }
          update_if(v, "cost_currency") { |cc| variant.cost_currency = cc }
          update_if(v, "weight") { |w| variant.weight = w.to_f }
          update_if(v, "width") { |w| variant.width = w.to_f }
          update_if(v, "height") { |w| variant.height = w.to_f }
          update_if(v, "depth") { |w| variant.depth = w.to_f }
          update_if(v, "cost_price") { |w| variant.cost_price = w.to_f }

          variant.save or return validate_to_error(variant)

          update_if v, "options" do |op; vals|
            vals = {}
            variant.option_values.each do |value|
              vals[value.option_type_id] = value
            end
            op.each do |kv|
              type = memo(:upsert_option_type, kv["name"]) or next
              value = memo(:upsert_option_value, type, kv["value"])
              vals[type.id] = value
            end
            variant.option_values = vals.values.compact
          end

          update_if v, "images" do |img|
            # TODO
          end
        end
    end
  end
end
