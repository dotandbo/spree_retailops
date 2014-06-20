SpreeRetailops
==============

This extension provides API access points for use by the RetailOps direct Spree integration.

Installation
------------

Add spree_retailops to your Gemfile:

```ruby
gem 'spree_retailops', git: 'https://github.com/GudTech/spree_retailops.git'
```

Bundle your dependencies and run the installation generator:

```shell
bundle
bundle exec rails g spree_retailops:install
```

Extensibility
-------------

Spree is extensible, and the Spree RetailOps extension tries to accomodate your other and custom extensions.
Several explicit and implicit extension points are provided for your use.
I'm a hard-liner about namespace pollution, so all global names created or interrogated by this extension will include "retailops" in them somewhere.

* Catalog feeds have "Extensions" sections in the images, product details, and variants sections.  If you have added columns to the `spree_assets`, `spree_products`, or `spree_variants` tables (respectively), you can use the column names to set the columns.  Any validations you provide will be checked, and failures will be expressed in RetailOps as system alerts.  The values will be set as strings; ActiveRecord seems to be able to coerce numeric and boolean columns, but foreign keys could be problematic.

* If you have product data extensions which are NOT new columns in one of those three tables, or if you have more involved data such as foreign keys, you can define a method named `retailops_extend_#{name}=` on one of those three tables to catch and reroute or reparse extended values.  For instance, a definition like `def retailops_extend_foo=(value); end` will catch a setting of the extension field "foo".

* Any column which you add to the `Order`, `LineItem`, `Shipment`, `Adjustment`, `Address`, `Payment`, or `CreditCard` models will be expressed in the order import data automatically.  Beware that the RetailOps order importer will ignore any unrecognized data until custom development is done within RetailOps itself to use it.

* For products that RetailOps should never attempt to ship, such as gift cards, add a method `retailops_is_advisory?` on `Spree::Product` or `Spree::LineItem`.  The `spree_gift_card` extension is handled automatically if present.

* The handling of tracking data can be overridden by defining a method named `retailops_set_tracking` on `Spree::Shipment`.

* To do something interesting with detailed inventory data such as JIT counts, define a method `def retailops_notify_inventory(details); end` on `Spree::Variant`.  The details argument is a hash, which currently resembles `{ "all" => 12, "by_type" => { "internal" => 5, "jit" => 12, "dropship" => 0 } }` although more keys may be defined in the future.  Internal means inventory units available without using any JIT or Dropship provididers; JIT is the increment inventory permitted by allowing JIT, and Dropship likewise.

Copyright (c) 2014 Gud Technologies, Inc, released under the New BSD License
