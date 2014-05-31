$(document).ready(function () {
  'use strict';

  $('a.retailops-set-importable').click(function () {
    var link = $(this);
    var order_number = link.data('order-number');
    var importable = link.data('importable');
    var url = Spree.url(Spree.routes.root + 'api/orders/' + order_number + '/retailops_importable.json');

    $.ajax({
      type: 'PUT',
      url: url,
      data: {
        importable: importable
      }
    }).done(function () {
      window.location.reload();
    }).error(function (msg) {
        console.log(msg);
    });
  });
});
