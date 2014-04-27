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

        products = if params["products_json"]
          # Workaround for https://github.com/rails/rails/issues/8832
          JSON.parse(params["products_json"])
        else
          params["products"]
        end

        products.is_a? Array or throw "products must be array"

        @diag = []
        @memo = {}
        ActiveRecord::Base.transaction do
          products.each { |pd| upsert_product pd }
        end

        render json: { "import_results" => @diag }
      #rescue => exn
      #  print exn, "\n", exn.backtrace.join("\n"), "\n"
      #  raise
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

          taxon = taxonomy.root

          taxon_names.each do |taxon_name|
            taxon = memo :upsert_taxon, (taxon && taxon.id), taxon_name do
              taxonomy.taxons.find_or_create_by!(parent_id: taxon.id, name: taxon_name)
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

          # no product?  OK then
          product ||= Product.new

          # Update product attributes
          update_if(pd, "tax_category") { |cat| product.tax_category = memo(:upsert_tax_category, cat) }
          update_if(pd, "available_on") { |avtime| product.available_on = avtime ? Time.at(avtime) : nil }
          update_if(pd, "slug") { |slug| product.slug = slug }
          update_if(pd, "name") { |name| product.name = name }
          update_if(pd, "meta_desc") { |md| product.meta_description = md }
          update_if(pd, "description") { |d| product.description = d }
          update_if(pd, "meta_keywords") { |mk| product.meta_keywords = mk }
          update_if(pd, "ship_category") { |sc| product.shipping_category = memo(:upsert_ship_category, sc) }

          # set things that hang off the product
          update_if pd, "options_used" do |opts|
            product.option_types = pd["options_used"].map { |opt| memo(:upsert_option_type, opt) }
          end

          update_if pd, "taxa" do |taxa|
            product.taxons = taxa.map { |path| upsert_taxon_path(path) }
          end

          update_if pd, "properties" do |prop|
            prop.each do |kv|
              #this does not erase properties ever, nor overwrite properties not mentioned
              #both of these are by design-ish
              next if kv["key"].blank?
              old_value = product.property(kv["key"])
              next if old_value == kv["value"] || !old_value && kv["value"].blank?
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

          update_if v, "images" do |imgs|
            update_images variant.images, imgs
          end

          update_if v, "stock" do |s|
            (@stocker ||= RopStockHelper.new).apply_stock(variant, s)
          end
        end

        # reconcile spree's images with a passed-in image list.  a passed-in
        # image can be satisfied by an existing image of the same name (ROP
        # image filenames are hashed to force uniqueness), or a matched
        # origin_url (this is an optimization for initial go-live when ROP
        # images are copied from spree images, we don't need to copy them
        # back).  All other images will be deleted...
        def update_images imgcoll, imglist
          stale = {}
          by_url = {}
          by_filename = {}

          imgcoll.each do |i|
            stale[i] = true
            #p "Existing image: ",i.attachment.url(:original),i.attachment.original_filename,i
            by_url[i.attachment.url(:original)] = i
            by_filename[i.attachment.original_filename] = i
          end

          imglist.each do |i|
            if old_i = by_url[i["origin_url"]] || by_filename[i["filename"]]
              #p "Reusing image: ",i,old_i
              old_i.update! alt: i["alt_text"]
              stale.delete(old_i)
            else
              #p "New image: ",i
              new_file = Paperclip.io_adapters.for(URI(i["url"]))
              new_file.original_filename = i["filename"]
              imgcoll.create!(attachment: new_file, alt: i["alt_text"])
            end
          end

          stale.each_key do |i|
            #p "Deleting old image: ",i
            i.destroy
          end
        end
    end
  end
end
