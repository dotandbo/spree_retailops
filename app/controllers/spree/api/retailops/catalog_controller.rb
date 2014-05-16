module Spree
  module Api
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

          @diag = []
          @memo = {}
          products.to_a.each { |pd| upsert_product_and_variants pd }

          render text: { "import_results" => @diag }.to_json
        end

        private
          def options
            params["options"] || {}
          end

          # Add diagnostics for the current product/variant.  Using this instead
          # of throwing an exception will cause the errors in RetailOps to be
          # associated to the exact SKU (instead of the entire batch), and
          # flagged as "user" errors rather than "system" errors.
          def add_error(msg)
            @diag << { "corr_id" => @current_corr_id, "message" => msg, "failed" => true }
          end

          def add_warn(msg)
            @diag << { "corr_id" => @current_corr_id, "message" => msg }
          end

          # Run a block and make sure any errors in it get routed to the right place
          def with_correlation(dto_in)
            old_id, @current_corr_id = @current_corr_id, dto_in["corr_id"]
            ActiveRecord::Base.transaction do
              yield
            end
          rescue Exception => exn
            @memo = {} # possibly stale IDs
            @diag << { "corr_id" => dto_in["corr_id"], "message" => exn.to_s, "failed" => true, "trace" => exn.backtrace }
          ensure
            @current_corr_id = old_id
          end

          def upsert_product_and_variants(pd)
            variant_sets = []
            with_correlation(pd) { upsert_product_only(pd, variant_sets) }
            variant_sets.each(&:call)
          end

          def validate_to_error(rec)
            rec.errors.to_a.each { |m| add_error(m) }
          end

          # Utilities
          def update_if(hash,key)
            yield hash[key] if hash.has_key? key
          end

          def memo(*args)
            return (@memo[args] ||= [block_given? ? yield : send(*args)])[0]
          end

          # Create if needed objects which products/variants can refer to.
          # Generally these should be called through #memo to avoid duplicative
          # queries (although you cannot rely on memo to catch everything;
          # string/number distinctions, for instance)
          def upsert_tax_category(cat)
            return cat.empty? ? nil : TaxCategory.find_or_create_by!(name: cat)
          end

          def upsert_ship_category(sc)
            return sc.empty? ? nil : ShippingCategory.find_or_create_by!(name: sc)
          end

          def upsert_property(pr)
            return pr.empty? ? nil : Property.find_or_create_by!(name: pr) { |r| r.presentation = pr }
          end

          def upsert_option_type(opt)
            return opt.blank? ? nil : OptionType.find_or_create_by!(name: opt) { |o| o.presentation = opt }
          end

          def upsert_option_value(type, value)
            return nil if value.blank?
            return type.option_values.find_or_create_by!(name: value) { |v| v.presentation = value }
          end

          # Taxon upserter does memoing internally due to common prefixes
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

          # This is where most of the fun happens: for a product, apply changes
          # and create if needed
          def upsert_product_only(pd, variant_sets)
            variant_list = pd['variants'].to_a
            return add_error("no variants specified") if variant_list.empty?
            # in the non-varying case, copy data up
            if !pd["varies"]
              v = variant_list[0]
              variant_list = []
              %w( images tax_category weight height depth width cost_price price cost_currency sku var_extend ).each do |c|
                pd[c] = v[c] if v.has_key?(c)
              end
            end

            return add_error("sku not specified") if pd["sku"].empty?

            # Try to use the existing SKU to pull up a product
            ex_variant = Variant.includes(:product).find_by(sku: pd["sku"], deleted_at: nil)
            if ex_variant && !ex_variant.is_master
              return add_error("sku number #{ex_variant.sku} is already used as a child sku, and cannot be used as a master here")
            end
            product = ex_variant && ex_variant.product

            # no product?  OK then
            product ||= Product.new

            # Update product attributes
            update_if(pd, "tax_category") { |cat| product.tax_category = memo(:upsert_tax_category, cat) }
            update_if(pd, "available_on") { |avtime| product.available_on = avtime ? Time.at(avtime) : nil }
            update_if(pd, "slug") { |slug| product.slug = slug } if product.respond_to? :slug= # renamed 2.2.x
            update_if(pd, "slug") { |slug| product.permalink = slug } if product.respond_to? :permalink= # renamed 2.2.x
            update_if(pd, "name") { |name| product.name = name }
            update_if(pd, "meta_desc") { |md| product.meta_description = md }
            update_if(pd, "description") { |d| product.description = d }
            update_if(pd, "meta_keywords") { |mk| product.meta_keywords = mk }
            update_if(pd, "ship_category") { |sc| product.shipping_category = memo(:upsert_ship_category, sc) }

            # set things that hang off the product
            update_if pd, "options_used" do |opts|
              product.option_types = pd["options_used"].to_a.map { |opt| memo(:upsert_option_type, opt) }
            end

            update_if pd, "taxa" do |taxa|
              product.taxons = taxa.to_a.map { |path| upsert_taxon_path(path) }
            end

            update_if pd, "properties" do |prop|
              ex_props = {}
              product.product_properties.each { |pp| ex_props[pp.property] = pp }

              prop.to_a.each do |kv|
                prop = memo(:upsert_property, kv["key"]) or next
                kv["value"].present? or next

                pprop = ex_props.delete(prop) || product.product_properties.build( property: prop )

                if pprop.value != kv["value"]
                  pprop.value = kv["value"]
                  pprop.save!
                end
              end

              ex_props.each_value(&:destroy!) if options['delete_old_properties']
            end

            update_if(pd, "prod_extend") { |e| apply_extensions product, e }

            # Create/update variants, including the master
            upsert_variant(product, product.master, pd)

            # product itself A-OK?  if not fail
            product.save or return validate_to_error(product)

            variant_list.each { |v| variant_sets << lambda { with_correlation(v) { upsert_variant(product, nil, v) } } }
          end

          def upsert_variant(product, variant, v)
            return add_error("no sku specified") if v["sku"].empty?

            unless variant
              variant = Variant.find_by(sku: v["sku"], deleted_at: nil)
              if variant && variant.is_master
                return add_error("sku number #{variant.sku} is already used as a master sku, and cannot be used as a child here")
              end

              if variant && variant.product_id != product.id
                # Oops.  Need to steal the SKU
                # Take the actual variant, because inventory reorganizations shouldn't affect wishlists, etc
                # There could be some fun fallout from this.  We'll deal with it as it comes up.
                variant.product = product
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
            update_if(v, "var_extend") { |e| apply_extensions variant, e }

            variant.save or return validate_to_error(variant)

            update_if v, "options" do |op; vals|
              vals = {}
              op.to_a.each do |kv|
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
              (@stocker ||= Spree::Retailops::RopStockHelper.new).apply_stock(variant, s)
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

            imglist.to_a.each do |i|
              if imgobj = by_url[i["origin_url"]] || by_filename[i["filename"]]
                #p "Reusing image: ",i,imgobj
                stale.delete(imgobj)
              else
                #p "New image: ",i
                new_file = Paperclip.io_adapters.for(URI(i["url"]))
                new_file.original_filename = i["filename"]
                imgobj = imgcoll.build(attachment: new_file)
              end
              imgobj.alt = i["alt_text"];
              apply_extensions imgobj, i["extend"]
              imgobj.save!
            end

            stale.each_key do |i|
              #p "Deleting old image: ",i
              i.destroy
            end
          end

          # Try to generically apply stuff that isn't standard Spree features
          def apply_extensions target, hash
            return unless hash
            hash.kind_of? Hash or raise "extension object must be a hash if provided"

            hash.each do |name, value|
              name = name.to_s; value = value.to_s

              if target.respond_to? "retailops_extend_#{name}="
                #allow specific behavior for custom development, if needed
                target.public_send("retailops_extend_#{name}=", value)
              elsif target.kind_of?(ActiveRecord::Base) && target.class.column_names.include?(name)
                # this is a little dangerous but it should catch 90% of custom development with no added work
                target.attributes = { name => value }
              elsif value.blank?
                # ignore attempts to delete an extension that never existed
              else
                # else carp
                add_warn("Extension field #{name} (#{target.class}) not available on this instance")
              end
            end
          end
      end
    end
  end
end
