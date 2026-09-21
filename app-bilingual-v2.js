document.addEventListener("DOMContentLoaded", function () {
  const SUPABASE_URL = "https://eswrqkhsvlqndjbrgsqo.supabase.co";
  const SUPABASE_KEY = "sb_publishable_-6iIwPaZQRMkkWAROdfvxg_dmVB81E2";
  const MESSENGER_PAGE = "cocaitiem.o.melbourne";
  const MESSENGER_PAGE_ID = "1204366336096979";
  const PAYID = "ĐIỀN PAYID CỦA TIỆM";
  let currentLang = localStorage.getItem("cct_lang") === "en" ? "en" : "vi";
  window.CCT_LANG = currentLang;

  const I18N = {
    vi: {
      all:"Tất cả", inStock:"Còn ", cartEmpty:t("cartEmpty"),
      optionSub:"Chọn option trước khi thêm vào giỏ", cancel:"Huỷ", addCart:"Thêm vào giỏ",
      choose:"Vui lòng chọn ", stockOnly:"Món này chỉ còn {n} phần.",
      cartRequired:"Vui lòng thêm sản phẩm vào giỏ hàng.", nameRequired:"Vui lòng nhập tên khách.",
      pickupRequired:"Vui lòng chọn ngày và giờ pick up.", shippingRequired:t("shippingRequired"),
      reserveFail:"Không thể giữ tồn kho cho đơn này.", insufficient:t("insufficient"),
      unavailable:t("unavailable"),
      total:"Tổng", receive:"Nhận hàng", pickupDate:"Ngày pick up", pickupTime:"Giờ pick up", phone:"SĐT",
      recipient:"Tên người nhận", address:"Địa chỉ", quoteLater:"báo giá sau khi tạo đơn", payment:"Thanh toán", note:"Ghi chú", noNote:"Không có",
      copied:t("copied"),
      copyFail:t("copyFail"),
      menuLoadFail:t("menuLoadFail"), noItems:t("noItems")
    },
    en: {
      all:"All", inStock:"In stock: ", cartEmpty:"Your cart is empty.",
      optionSub:"Choose options before adding to cart", cancel:"Cancel", addCart:"Add to cart",
      choose:"Please choose ", stockOnly:"Only {n} left in stock.",
      cartRequired:"Please add a product to your cart.", nameRequired:"Please enter your name.",
      pickupRequired:"Please choose a pickup date and time.", shippingRequired:"Please enter the recipient name, phone number and delivery address.",
      reserveFail:"Unable to reserve stock for this order.", insufficient:"One item no longer has enough stock. Please refresh the menu and choose again.",
      unavailable:"One item has just sold out or is no longer available. Please refresh the menu.",
      total:"Total", receive:"Fulfilment", pickupDate:"Pickup date", pickupTime:"Pickup time", phone:"Phone",
      recipient:"Recipient", address:"Address", quoteLater:"delivery fee quoted after order", payment:"Payment", note:"Note", noNote:"None",
      copied:"Order copied. Next, tap Send via Messenger, paste the order into the chat and send it.",
      copyFail:"Your browser could not copy automatically. Please select and copy the order manually.",
      menuLoadFail:"Unable to load the menu. Please try again later.", noItems:"There are no items in this category yet."
    }
  };

  function t(key){ return I18N[currentLang][key] || I18N.vi[key] || key; }

  let PRODUCTS = [];
  let CATEGORIES = [];
  const cart = [];
  window.CCT_CART = cart;
  let currentOrderToken = null;
  let currentOrderCommitted = false;

  const productGrid = document.getElementById("productGrid");
  const cartCount = document.getElementById("cartCount");
  const cartDrawer = document.getElementById("cartDrawer");
  const overlay = document.getElementById("overlay");
  const cartList = document.getElementById("cartList");
  const cartTotal = document.getElementById("cartTotal");
  const deliveryMethod = document.getElementById("deliveryMethod");
  const pickupFields = document.getElementById("pickupFields");
  const pickupDate = document.getElementById("pickupDate");
  const pickupTime = document.getElementById("pickupTime");
  const pickupPhone = document.getElementById("pickupPhone");
  const shippingFields = document.getElementById("shippingFields");
  const recipientName = document.getElementById("recipientName");
  const recipientPhone = document.getElementById("recipientPhone");
  const shippingAddress = document.getElementById("shippingAddress");
  const orderBox = document.getElementById("orderBox");
  const orderHelp = document.getElementById("orderHelp");
  const copyOrderBtn = document.getElementById("copyOrderBtn");
  const messengerBtn = document.getElementById("messengerBtn");

  function money(value) {
    return Number(value || 0).toFixed(2).replace(".00", "");
  }

  function escapeHtml(value) {
    return String(value ?? "").replace(/[&<>"']/g, function (char) {
      return {
        "&": "&amp;",
        "<": "&lt;",
        ">": "&gt;",
        '"': "&quot;",
        "'": "&#39;"
      }[char];
    });
  }

  async function loadCategories() {
    try {
      const response = await fetch(
        SUPABASE_URL + "/rest/v1/product_categories?select=slug,label,label_en,sort_order,is_active&is_active=eq.true&order=sort_order.asc,slug.asc",
        {
          headers: {
            apikey: SUPABASE_KEY,
            Authorization: "Bearer " + SUPABASE_KEY
          }
        }
      );

      if (!response.ok) throw new Error("Không tải được category");
      CATEGORIES = await response.json();
      window.CCT_CATEGORIES = CATEGORIES;
    } catch (error) {
      console.error(error);
      CATEGORIES = [];
    }
  }

  function renderFilters() {
    const filters = document.getElementById("filters");
    const seen = new Set();
    const inferred = PRODUCTS.map(function (p) { return p.category; }).filter(Boolean);

    const categoryList = CATEGORIES.slice();

    inferred.forEach(function (slug) {
      if (!categoryList.some(function (c) { return c.slug === slug; })) {
        categoryList.push({
          slug: slug,
          label: slug.charAt(0).toUpperCase() + slug.slice(1),
          sort_order: 999
        });
      }
    });

    const buttons = ['<button class="filter active" type="button" data-category="all">' + escapeHtml(t("all")) + '</button>'];

    categoryList.forEach(function (category) {
      if (seen.has(category.slug)) return;
      seen.add(category.slug);
      buttons.push(
        '<button class="filter" type="button" data-category="' +
        escapeHtml(category.slug) +
        '">' +
        escapeHtml(currentLang === "en" && category.label_en ? category.label_en : category.label) +
        '</button>'
      );
    });

    filters.innerHTML = buttons.join("");

    filters.querySelectorAll(".filter").forEach(function (button) {
      button.addEventListener("click", function () {
        filters.querySelectorAll(".filter").forEach(function (item) {
          item.classList.remove("active");
        });
        button.classList.add("active");
        renderProducts(button.dataset.category);
      });
    });
  }

  async function loadProducts() {
    try {
      const url =
        SUPABASE_URL +
        "/rest/v1/products" +
        "?select=id,name,name_en,price,category,emoji,description,description_en,image_url,sort_order,is_active,stock_qty,option_groups,option_groups_en" +
        "&is_active=eq.true" +
        "&or=(stock_qty.is.null,stock_qty.gt.0)" +
        "&order=sort_order.asc,id.asc";

      const response = await fetch(url, {
        headers: {
          apikey: SUPABASE_KEY,
          Authorization: "Bearer " + SUPABASE_KEY
        }
      });

      if (!response.ok) {
        throw new Error("Không tải được menu");
      }

      const data = await response.json();

      PRODUCTS = data.map(function (p) {
        return {
          id: p.id,
          name_vi: p.name,
          name_en: p.name_en || p.name,
          name: currentLang === "en" && p.name_en ? p.name_en : p.name,
          price: Number(p.price),
          category: p.category,
          emoji: p.emoji || "🍋",
          description_vi: p.description || "",
          description_en: p.description_en || p.description || "",
          description: currentLang === "en" && p.description_en ? p.description_en : (p.description || ""),
          image_url: p.image_url || "",
          sort_order: Number(p.sort_order || 0),
          stock_qty: p.stock_qty === null ? null : Number(p.stock_qty),
          option_groups_vi: Array.isArray(p.option_groups) ? p.option_groups : [],
          option_groups_en: Array.isArray(p.option_groups_en) && p.option_groups_en.length ? p.option_groups_en : (Array.isArray(p.option_groups) ? p.option_groups : []),
          option_groups: currentLang === "en" && Array.isArray(p.option_groups_en) && p.option_groups_en.length ? p.option_groups_en : (Array.isArray(p.option_groups) ? p.option_groups : [])
        };
      });
      window.CCT_PRODUCTS = PRODUCTS;
    } catch (error) {
      console.error(error);
      productGrid.innerHTML = '<div style="grid-column:1/-1;padding:20px;background:#fff;border-radius:14px">Không tải được menu. Vui lòng thử lại sau.</div>';
    }
  }

  function renderProducts(category) {
    const selected =
      category === "all"
        ? PRODUCTS
        : PRODUCTS.filter(function (product) {
            return product.category === category;
          });

    if (!selected.length) {
      productGrid.innerHTML = '<div style="grid-column:1/-1;padding:20px;background:#fff;border-radius:14px">Hiện chưa có món trong mục này.</div>';
      return;
    }

    productGrid.innerHTML = selected
      .map(function (product) {
        const index = PRODUCTS.indexOf(product);
        const visual = product.image_url
          ? '<img src="' +
            escapeHtml(product.image_url) +
            '" alt="' +
            escapeHtml(product.name) +
            '" style="width:100%;height:100%;object-fit:cover">'
          : product.emoji;

        const stockText =
          product.stock_qty === null
            ? ""
            : '<div style="font-size:12px;color:#806f61;margin-top:6px">Còn ' +
              product.stock_qty +
              "</div>";

        return [
          '<div class="product-card">',
          '<div class="product-visual">',
          visual,
          "</div>",
          '<div class="product-body">',
          "<h3>",
          escapeHtml(product.name),
          "</h3>",
          '<div class="product-desc">',
          escapeHtml(product.description),
          "</div>",
          stockText,
          '<div class="product-bottom">',
          '<span class="price">$',
          money(product.price),
          "</span>",
          '<button class="add-btn" type="button" data-add-index="',
          index,
          '">+</button>',
          "</div>",
          "</div>",
          "</div>"
        ].join("");
      })
      .join("");
  }

  function updateCart() {
    const totalQty = cart.reduce(function (sum, item) {
      return sum + item.qty;
    }, 0);

    const totalPrice = cart.reduce(function (sum, item) {
      return sum + item.price * item.qty;
    }, 0);

    cartCount.textContent = totalQty;
    cartTotal.textContent = money(totalPrice);

    if (cart.length === 0) {
      cartList.innerHTML = "Giỏ hàng đang trống.";
      return;
    }

    cartList.innerHTML = cart
      .map(function (item, index) {
        return [
          '<div class="cart-row">',
          "<div>",
          "<b>",
          escapeHtml(item.name),
          "</b>",
          item.option_text ? "<br><small>" + escapeHtml(item.option_text) + "</small>" : "",
          "<br>",
          "<small>$",
          money(item.price),
          " × ",
          item.qty,
          "</small>",
          "</div>",
          '<div class="qty-btns">',
          '<button type="button" data-cart-index="',
          index,
          '" data-delta="-1">−</button> ',
          '<button type="button" data-cart-index="',
          index,
          '" data-delta="1">＋</button>',
          "</div>",
          "</div>"
        ].join("");
      })
      .join("");
  }

  function openCart() {
    overlay.classList.add("show");
    cartDrawer.classList.add("show");
    cartDrawer.setAttribute("aria-hidden", "false");
    updateCart();
  }

  function closeCart() {
    overlay.classList.remove("show");
    cartDrawer.classList.remove("show");
    cartDrawer.setAttribute("aria-hidden", "true");
  }

  function syncShippingFields() {
    const isPickup = deliveryMethod.value === "pickup";

    pickupFields.style.display = isPickup ? "block" : "none";
    shippingFields.style.display = isPickup ? "none" : "block";

    if (isPickup) {
      recipientName.value = "";
      recipientPhone.value = "";
      shippingAddress.value = "";
    } else {
      pickupDate.value = "";
      pickupTime.value = "";
    }
  }

  function resetOrderReservation() {
    currentOrderToken = null;
    currentOrderCommitted = false;
  }

  window.CCT_updateCart = updateCart;
  window.CCT_resetOrderReservation = resetOrderReservation;

  async function saveOrderDetails(orderText, customerName) {
    const response = await fetch(
      SUPABASE_URL + "/rest/v1/rpc/save_order_details",
      {
        method: "POST",
        headers: {
          apikey: SUPABASE_KEY,
          Authorization: "Bearer " + SUPABASE_KEY,
          "Content-Type": "application/json"
        },
        body: JSON.stringify({
          p_order_token: currentOrderToken,
          p_customer_name: customerName,
          p_order_text: orderText
        })
      }
    );

    if (!response.ok) {
      throw new Error("Không lưu được nội dung đơn hàng.");
    }
  }

  function makeOrderToken() {
    if (window.crypto && crypto.randomUUID) {
      return crypto.randomUUID();
    }
    return "order-" + Date.now() + "-" + Math.random().toString(36).slice(2);
  }

  async function commitStockForCurrentCart() {
    if (currentOrderCommitted) {
      return { ok: true, duplicate: true };
    }

    if (!currentOrderToken) {
      currentOrderToken = makeOrderToken();
    }

    const items = cart.map(function (item) {
      return { id: item.id, qty: item.qty };
    });

    const response = await fetch(
      SUPABASE_URL + "/rest/v1/rpc/commit_order_stock",
      {
        method: "POST",
        headers: {
          apikey: SUPABASE_KEY,
          Authorization: "Bearer " + SUPABASE_KEY,
          "Content-Type": "application/json"
        },
        body: JSON.stringify({
          p_order_token: currentOrderToken,
          p_items: items
        })
      }
    );

    const bodyText = await response.text();

    if (!response.ok) {
      let message = t("reserveFail");

      if (bodyText.includes("insufficient_stock")) {
        message =
          "Một món trong giỏ không còn đủ số lượng. Vui lòng tải lại menu và chọn lại.";
      } else if (bodyText.includes("product_unavailable")) {
        message =
          "Một món trong giỏ vừa hết hàng hoặc đã ngừng bán. Vui lòng tải lại menu.";
      }

      throw new Error(message);
    }

    currentOrderCommitted = true;

    if (!bodyText) {
      return { ok: true };
    }

    try {
      return JSON.parse(bodyText);
    } catch (error) {
      return { ok: true };
    }
  }

  document.getElementById("openCartBtn").addEventListener("click", openCart);
  document.getElementById("closeCartBtn").addEventListener("click", closeCart);
  overlay.addEventListener("click", closeCart);

  function chooseProductOptions(product) {
    return new Promise(function (resolve) {
      const groups = Array.isArray(product.option_groups) ? product.option_groups : [];
      if (!groups.length) {
        resolve([]);
        return;
      }

      const backdrop = document.createElement("div");
      backdrop.className = "option-modal-backdrop";

      const modal = document.createElement("div");
      modal.className = "option-modal";

      let html =
        '<div class="option-modal-head">' +
          '<div><strong>' + escapeHtml(product.name) + '</strong><div class="option-modal-sub">' + escapeHtml(t("optionSub")) + '</div></div>' +
          '<button type="button" class="option-modal-close">✕</button>' +
        '</div>' +
        '<div class="option-modal-body">';

      groups.forEach(function (group, groupIndex) {
        html += '<div class="option-group">' +
          '<div class="option-group-title">' + escapeHtml(group.name || ("Option " + (groupIndex + 1))) + '</div>';

        (group.choices || []).forEach(function (choice, choiceIndex) {
          const id = "opt-" + groupIndex + "-" + choiceIndex + "-" + Date.now();
          html +=
            '<label class="option-choice" for="' + id + '">' +
              '<input id="' + id + '" type="radio" name="option-group-' + groupIndex + '" value="' + escapeHtml(choice) + '">' +
              '<span>' + escapeHtml(choice) + '</span>' +
            '</label>';
        });

        html += '</div>';
      });

      html +=
        '</div>' +
        '<div class="option-modal-actions">' +
          '<button type="button" class="option-cancel-btn">' + escapeHtml(t("cancel")) + '</button>' +
          '<button type="button" class="option-confirm-btn">' + escapeHtml(t("addCart")) + '</button>' +
        '</div>';

      modal.innerHTML = html;
      backdrop.appendChild(modal);
      document.body.appendChild(backdrop);

      function close(result) {
        backdrop.remove();
        resolve(result);
      }

      modal.querySelector(".option-modal-close").addEventListener("click", function () { close(null); });
      modal.querySelector(".option-cancel-btn").addEventListener("click", function () { close(null); });
      backdrop.addEventListener("click", function (e) {
        if (e.target === backdrop) close(null);
      });

      modal.querySelector(".option-confirm-btn").addEventListener("click", function () {
        const selected = [];

        for (let i = 0; i < groups.length; i += 1) {
          const checked = modal.querySelector('input[name="option-group-' + i + '"]:checked');
          if (!checked && groups[i].required !== false) {
            alert(t("choose") + (groups[i].name || "option") + ".");
            return;
          }

          if (checked) {
            selected.push({
              group: groups[i].name || ("Option " + (i + 1)),
              choice: checked.value
            });
          }
        }

        close(selected);
      });
    });
  }

  productGrid.addEventListener("click", async function (event) {
    const button = event.target.closest("[data-add-index]");
    if (!button) {
      return;
    }

    const product = PRODUCTS[Number(button.dataset.addIndex)];
    if (!product) {
      return;
    }

    const selectedOptions = await chooseProductOptions(product);
    if (selectedOptions === null) {
      return;
    }

    const optionText = selectedOptions.map(function (opt) {
      return opt.choice;
    }).join(" • ");

    const variantKey = product.id + "::" + optionText;

    const existing = cart.find(function (item) {
      return item.variant_key === variantKey;
    });

    const totalForProduct = cart
      .filter(function (item) { return item.id === product.id; })
      .reduce(function (sum, item) { return sum + item.qty; }, 0);

    if (
      product.stock_qty !== null &&
      totalForProduct >= product.stock_qty
    ) {
      alert(t("stockOnly").replace("{n}", product.stock_qty));
      return;
    }

    if (existing) {
      existing.qty += 1;
    } else {
      cart.push({
        id: product.id,
        name: product.name,
        price: product.price,
        qty: 1,
        stock_qty: product.stock_qty,
        options: selectedOptions,
        option_text: optionText,
        variant_key: variantKey
      });
    }

    resetOrderReservation();
    updateCart();
  });

  cartList.addEventListener("click", function (event) {
    const button = event.target.closest("[data-cart-index]");
    if (!button) {
      return;
    }

    const index = Number(button.dataset.cartIndex);
    const delta = Number(button.dataset.delta);
    const item = cart[index];

    if (!item) {
      return;
    }

    if (delta > 0 && item.stock_qty !== null) {
      const totalForProduct = cart
        .filter(function (cartItem) { return cartItem.id === item.id; })
        .reduce(function (sum, cartItem) { return sum + cartItem.qty; }, 0);

      if (totalForProduct >= item.stock_qty) {
        alert(t("stockOnly").replace("{n}", item.stock_qty));
        return;
      }
    }

    item.qty += delta;

    if (item.qty <= 0) {
      cart.splice(index, 1);
    }

    resetOrderReservation();
    updateCart();
  });

  deliveryMethod.addEventListener("change", syncShippingFields);

  document
    .getElementById("makeOrderBtn")
    .addEventListener("click", async function () {
      if (cart.length === 0) {
        alert(t("cartRequired"));
        return;
      }

      const customerName = document
        .getElementById("customerName")
        .value.trim();

      const payment = document.querySelector(
        'input[name="payment"]:checked'
      ).value;

      const note =
        document.getElementById("customerNote").value.trim() || t("noNote");

      if (!customerName) {
        alert(t("nameRequired"));
        return;
      }

      if (deliveryMethod.value === "pickup") {
        if (!pickupDate.value || !pickupTime.value) {
          alert(t("pickupRequired"));
          return;
        }
      } else {
        if (
          !recipientName.value.trim() ||
          !recipientPhone.value.trim() ||
          !shippingAddress.value.trim()
        ) {
          alert(
            "Vui lòng nhập tên người nhận, số điện thoại và địa chỉ nhận hàng."
          );
          return;
        }
      }

      try {
        await commitStockForCurrentCart();
      } catch (error) {
        alert(error.message);
        await loadProducts();
        renderFilters();
        renderProducts("all");
        return;
      }

      const deliveryLabels = {
        pickup: "Pick up Springvale",
        delivery: "Delivery Melbourne",
        auspost: "AusPost"
      };

      const totalPrice = cart.reduce(function (sum, item) {
        return sum + item.price * item.qty;
      }, 0);

      const lines = cart
        .map(function (item) {
          return (
            item.qty +
            " x " +
            item.name +
            (item.option_text ? " — " + item.option_text : "") +
            " $" +
            money(item.price * item.qty)
          );
        })
        .join("\n");

      let text =
        customerName +
        "\n" +
        lines +
        "\n" +
        t("total") + ": $" +
        money(totalPrice) +
        "\n";

      if (deliveryMethod.value === "pickup") {
        text +=
          t("receive") + ": Pick up Springvale" +
          "\n" + t("pickupDate") + ": " +
          pickupDate.value +
          "\n" + t("pickupTime") + ": " +
          pickupTime.value +
          (pickupPhone && pickupPhone.value.trim()
            ? "\n" + t("phone") + ": " + pickupPhone.value.trim()
            : "");
      } else {
        text +=
          t("receive") + ": " +
          deliveryLabels[deliveryMethod.value] +
          " (" + t("quoteLater") + ")" +
          "\n" + t("recipient") + ": " +
          recipientName.value.trim() +
          "\n" + t("phone") + ": " +
          recipientPhone.value.trim() +
          "\n" + t("address") + ": " +
          shippingAddress.value.trim();
      }

      text +=
        "\n" + t("payment") + ": " + payment + "\n" + t("note") + ": " + note;

      if (payment === "PayID") {
        text += "\n\nPayID: " + PAYID;
      }

      orderBox.textContent = text;
      orderBox.style.display = "block";
      orderHelp.style.display = "block";
      copyOrderBtn.style.display = "block";
      messengerBtn.style.display = "block";

      requestAnimationFrame(function () {
        orderBox.scrollIntoView({
          behavior: "smooth",
          block: "start"
        });
      });

      try {
        await saveOrderDetails(text, customerName);
      } catch (saveError) {
        console.error(saveError);
      }

      await loadProducts();
      renderFilters();
      renderProducts("all");
    });

  copyOrderBtn.addEventListener("click", async function () {
    try {
      await navigator.clipboard.writeText(orderBox.textContent);
      alert(
        "Đã copy đơn hàng. Tiếp theo bấm Gửi qua Messenger, dán nội dung đơn vào khung chat rồi bấm Send."
      );
    } catch (error) {
      alert(
        "Trình duyệt không cho copy tự động. Vui lòng chọn nội dung đơn và copy thủ công."
      );
    }
  });

  messengerBtn.addEventListener("click", function () {
    const isMobile = /iPhone|iPad|iPod|Android/i.test(navigator.userAgent);
    const webUrl = "https://m.me/" + encodeURIComponent(MESSENGER_PAGE);

    if (!isMobile) {
      window.open(webUrl, "_blank");
      return;
    }

    const appUrl = "fb-messenger://user-thread/" + encodeURIComponent(MESSENGER_PAGE_ID);
    const started = Date.now();

    window.location.href = appUrl;

    setTimeout(function () {
      if (Date.now() - started < 1800) {
        window.location.href = webUrl;
      }
    }, 900);
  });

  function applyStaticLanguage() {
    document.documentElement.lang = currentLang === "en" ? "en" : "vi";
    const en = currentLang === "en";

    const setText = function(selector, value) {
      const el = document.querySelector(selector);
      if (el) el.textContent = value;
    };

    setText(".topbar", en ? "In stock • Pick up Springvale • Melbourne delivery • AusPost from $12" : "Hàng có sẵn • Pick up Springvale • Delivery Melbourne • AusPost từ $12");
    setText(".hero-subtitle", en ? "Melbourne Vietnamese Snacks" : "Ăn vặt Melbourne");
    setText(".hero-tagline", en ? "Tasty bites for brighter days ♡" : "Món ngon cho những ngày thêm vui ♡");
    setText(".hero-note", en ? "🛒 Easy ordering • Cash or PayID" : "🛒 Order dễ dàng • Cash hoặc PayID");
    setText(".main h2", "Menu");

    const cartBtn = document.getElementById("openCartBtn");
    if (cartBtn) cartBtn.childNodes[0].nodeValue = en ? "🛒 Cart " : "🛒 Giỏ hàng ";

    const drawerTitle = document.querySelector(".drawer-head strong");
    if (drawerTitle) drawerTitle.textContent = en ? "Cart" : "Giỏ hàng";

    const totalLabel = document.querySelector(".total-row span:first-child");
    if (totalLabel) totalLabel.textContent = en ? "Total" : "Tổng";

    const labels = {
      customerName: en ? "Customer name" : "Tên khách",
      deliveryMethod: en ? "Fulfilment" : "Nhận hàng",
      pickupDate: en ? "Pickup date" : "Chọn ngày pick up",
      pickupTime: en ? "Pickup time" : "Chọn giờ pick up",
      pickupPhone: en ? "Phone number " : "Số điện thoại ",
      recipientName: en ? "Recipient name" : "Tên người nhận",
      recipientPhone: en ? "Phone number" : "Số điện thoại",
      shippingAddress: en ? "Delivery address" : "Địa chỉ nhận hàng",
      customerNote: en ? "Note" : "Ghi chú"
    };

    Object.keys(labels).forEach(function(id){
      const label=document.querySelector('label[for="'+id+'"]');
      if(label){
        if(id==="pickupPhone"){
          label.innerHTML = labels[id] + '<span class="optional-text">' + (en ? "(optional)" : "(không bắt buộc)") + '</span>';
        } else {
          label.textContent=labels[id];
        }
      }
    });

    const paymentLabel = document.querySelector(".pay-options")?.previousElementSibling;
    if (paymentLabel && paymentLabel.tagName === "LABEL") paymentLabel.textContent = en ? "Payment" : "Thanh toán";

    const noteInput=document.getElementById("customerNote");
    if(noteInput) noteInput.placeholder=en ? "E.g. mild spice, call before delivery..." : "Ví dụ: ít cay, gọi trước khi giao...";
    const nameInput=document.getElementById("customerName");
    if(nameInput) nameInput.placeholder=en ? "Your name" : "Tên của bạn";
    const addressInput=document.getElementById("shippingAddress");
    if(addressInput) addressInput.placeholder=en ? "Street, suburb, postcode" : "Số nhà, tên đường, suburb, postcode";

    const deliverySelect=document.getElementById("deliveryMethod");
    if(deliverySelect){
      const pickupOpt=deliverySelect.querySelector('option[value="pickup"]');
      const deliveryOpt=deliverySelect.querySelector('option[value="delivery"]');
      const auspostOpt=deliverySelect.querySelector('option[value="auspost"]');
      if(pickupOpt) pickupOpt.textContent="Pick up Springvale";
      if(deliveryOpt) deliveryOpt.textContent=en ? "Melbourne Delivery" : "Delivery Melbourne";
      if(auspostOpt) auspostOpt.textContent="AusPost";
    }

    const serviceValues=document.querySelectorAll(".service-value");
    if(serviceValues[2]) serviceValues[2].textContent=en ? "from $12" : "từ $12";

    const recipientNameInput=document.getElementById("recipientName");
    if(recipientNameInput) recipientNameInput.placeholder=en ? "Recipient name" : "Tên người nhận";
    const recipientPhoneInput=document.getElementById("recipientPhone");
    if(recipientPhoneInput) recipientPhoneInput.placeholder="04xx xxx xxx";

    const makeBtn=document.getElementById("makeOrderBtn");
    if(makeBtn) makeBtn.textContent=en ? "Create order" : "Tạo đơn hàng";
    if(copyOrderBtn) copyOrderBtn.textContent=en ? "📋 Copy order" : "📋 Copy đơn hàng";
    if(messengerBtn) messengerBtn.textContent=en ? "💬 Send via Messenger @cocaitiem.o.melbourne" : "💬 Gửi qua Messenger @cocaitiem.o.melbourne";
    const emailBtn=document.getElementById("emailOrderBtn");
    if(emailBtn && !emailBtn.disabled) emailBtn.textContent=en ? "✉️ Send order by Email" : "✉️ Gửi đơn hàng qua Email";

    const help=document.getElementById("orderHelp");
    if(help){
      help.innerHTML = en
        ? '<strong>Choose 1 way to send your order:</strong><div class="send-option"><strong>1. Send via Messenger</strong><br>Copy order → open Messenger <strong>@cocaitiem.o.melbourne</strong> → Paste and Send.</div><div class="send-option"><strong>2. Send by Email</strong><br>Send the order directly to the shop and wait for confirmation by phone.</div>'
        : '<strong>Chọn 1 cách gửi đơn:</strong><div class="send-option"><strong>1. Gửi qua Messenger</strong><br>Copy đơn hàng → mở Messenger <strong>@cocaitiem.o.melbourne</strong> → Paste và Send.</div><div class="send-option"><strong>2. Gửi qua Email</strong><br>Gửi đơn trực tiếp cho Tiệm và chờ xác nhận qua số điện thoại.</div>';
    }

    document.querySelectorAll(".language-btn").forEach(function(btn){
      btn.classList.toggle("active", btn.dataset.lang===currentLang);
    });

    const note=document.querySelector(".field-note");
    if(note) note.textContent=en ? "Only required if you choose to send the order by Email." : "Chỉ bắt buộc nếu bạn chọn gửi đơn qua Email.";
  }

  function applyProductLanguage() {
    PRODUCTS.forEach(function(product){
      product.name = currentLang === "en" ? (product.name_en || product.name_vi) : product.name_vi;
      product.description = currentLang === "en" ? (product.description_en || product.description_vi) : product.description_vi;
      product.option_groups = currentLang === "en" ? product.option_groups_en : product.option_groups_vi;
    });

    cart.forEach(function(item){
      const product=PRODUCTS.find(function(p){return Number(p.id)===Number(item.id);});
      if(!product) return;
      item.name=product.name;

      if(Array.isArray(item.options) && item.options.length){
        const sourceGroups=currentLang==="en" ? product.option_groups_vi : product.option_groups_en;
        const targetGroups=currentLang==="en" ? product.option_groups_en : product.option_groups_vi;
        item.options=item.options.map(function(opt,groupIndex){
          const source=sourceGroups[groupIndex] || {};
          const target=targetGroups[groupIndex] || {};
          const sourceChoices=Array.isArray(source.choices)?source.choices:[];
          const targetChoices=Array.isArray(target.choices)?target.choices:[];
          let choiceIndex=sourceChoices.indexOf(opt.choice);
          if(choiceIndex<0){
            choiceIndex=targetChoices.indexOf(opt.choice);
          }
          const choice=choiceIndex>=0 && targetChoices[choiceIndex] ? targetChoices[choiceIndex] : opt.choice;
          return {group:target.name || opt.group,choice:choice};
        });
        item.option_text=item.options.map(function(opt){return opt.choice;}).join(" • ");
        item.variant_key=item.id+"::"+item.option_text;
      }
    });
  }

  window.CCT_setLanguage = function(lang) {
    currentLang = lang === "en" ? "en" : "vi";
    window.CCT_LANG=currentLang;
    localStorage.setItem("cct_lang",currentLang);
    applyProductLanguage();
    renderFilters();
    renderProducts("all");
    updateCart();
    applyStaticLanguage();
  };

  document.querySelectorAll(".language-btn").forEach(function(btn){
    btn.addEventListener("click",function(){
      window.CCT_setLanguage(btn.dataset.lang);
    });
  });

  const today = new Date();
  const yyyy = today.getFullYear();
  const mm = String(today.getMonth() + 1).padStart(2, "0");
  const dd = String(today.getDate()).padStart(2, "0");
  pickupDate.min = yyyy + "-" + mm + "-" + dd;

  Promise.all([loadCategories(), loadProducts()]).then(function () {
    applyProductLanguage();
    renderFilters();
    renderProducts("all");
    applyStaticLanguage();
  });

  updateCart();
  syncShippingFields();
  applyStaticLanguage();
});