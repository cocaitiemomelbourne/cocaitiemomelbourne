document.addEventListener("DOMContentLoaded", function () {
  var api = window.CCT_API;
  var grid = document.getElementById("featuredGrid");
  if (!api || !grid) return;

  var preferredIds = [10, 5, 2, 1];

  function inStock(product) {
    return product && (product.stock_qty === null || product.stock_qty === undefined || Number(product.stock_qty) > 0);
  }

  function selectFeatured() {
    var products = api.getProducts().slice();
    var selected = [];

    preferredIds.forEach(function (id) {
      var product = products.find(function (item) { return Number(item.id) === id; });
      if (inStock(product)) selected.push(product);
    });

    var finiteFallbacks = products
      .filter(function (product) {
        return !selected.some(function (item) { return Number(item.id) === Number(product.id); }) &&
          !preferredIds.some(function (id) { return id === Number(product.id); }) &&
          product.stock_qty !== null && product.stock_qty !== undefined && Number(product.stock_qty) > 0;
      })
      .sort(function (a, b) {
        var diff = Number(b.stock_qty) - Number(a.stock_qty);
        return diff || Number(a.id) - Number(b.id);
      });

    finiteFallbacks.forEach(function (product) {
      if (selected.length < 4) selected.push(product);
    });

    if (selected.length < 4) {
      products.forEach(function (product) {
        if (selected.length >= 4) return;
        var already = selected.some(function (item) { return Number(item.id) === Number(product.id); });
        var preferred = preferredIds.some(function (id) { return id === Number(product.id); });
        if (!already && !preferred && inStock(product)) selected.push(product);
      });
    }

    return selected.slice(0, 4);
  }

  function render() {
    var featured = selectFeatured();
    grid.innerHTML = "";

    featured.forEach(function (p) {
      var card = document.createElement("div");
      card.className = "featured-card";

      var image = document.createElement("div");
      image.className = "featured-img";
      if (p.image_url) {
        var img = document.createElement("img");
        img.loading = "lazy";
        img.decoding = "async";
        img.fetchPriority = "low";
        img.src = p.image_url;
        img.alt = p.name || "";
        image.appendChild(img);
      } else {
        image.textContent = "🍋";
      }

      var body = document.createElement("div");
      body.className = "featured-body";
      var name = document.createElement("div");
      name.className = "featured-name";
      name.textContent = (window.CCT_LANG === "en" && p.name_en) ? p.name_en : p.name;

      var bottom = document.createElement("div");
      bottom.className = "featured-bottom";
      var price = document.createElement("strong");
      price.textContent = "$" + Number(p.price || 0).toFixed(2).replace(/\.00$/, "");
      var add = document.createElement("button");
      add.type = "button";
      add.className = "featured-add";
      add.textContent = "+";
      add.dataset.productId = String(p.id);
      bottom.appendChild(price);
      bottom.appendChild(add);

      body.appendChild(name);
      body.appendChild(bottom);
      card.appendChild(image);
      card.appendChild(body);
      grid.appendChild(card);
    });
  }

  setTimeout(render, 250);

  document.querySelectorAll("[data-lang]").forEach(function (button) {
    button.addEventListener("click", function () { setTimeout(render, 80); });
  });
});
