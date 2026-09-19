document.addEventListener("DOMContentLoaded", function () {
  const SUPABASE_URL = "https://eswrqkhsvlqndjbrgsqo.supabase.co";
  const SUPABASE_KEY = "sb_publishable_-6iIwPaZQRMkkWAROdfvxg_dmVB81E2";
  const MESSENGER_PAGE = "cocaitiem.o.melbourne";
  const PAYID = "ĐIỀN PAYID CỦA TIỆM";

  let PRODUCTS = [];
  const cart = [];
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

  async function loadProducts() {
    try {
      const url =
        SUPABASE_URL +
        "/rest/v1/products" +
        "?select=id,name,price,category,emoji,description,image_url,sort_order,is_active,stock_qty" +
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
          name: p.name,
          price: Number(p.price),
          category: p.category,
          emoji: p.emoji || "🍋",
          description: p.description || "",
          image_url: p.image_url || "",
          sort_order: Number(p.sort_order || 0),
          stock_qty: p.stock_qty === null ? null : Number(p.stock_qty)
        };
      });
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
          "</b><br>",
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
      let message = "Không thể giữ tồn kho cho đơn này.";

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

  document.querySelectorAll(".filter").forEach(function (button) {
    button.addEventListener("click", function () {
      document.querySelectorAll(".filter").forEach(function (item) {
        item.classList.remove("active");
      });

      button.classList.add("active");
      renderProducts(button.dataset.category);
    });
  });

  productGrid.addEventListener("click", function (event) {
    const button = event.target.closest("[data-add-index]");
    if (!button) {
      return;
    }

    const product = PRODUCTS[Number(button.dataset.addIndex)];
    if (!product) {
      return;
    }

    const existing = cart.find(function (item) {
      return item.id === product.id;
    });

    if (
      product.stock_qty !== null &&
      existing &&
      existing.qty >= product.stock_qty
    ) {
      alert("Món này chỉ còn " + product.stock_qty + " phần.");
      return;
    }

    if (
      product.stock_qty !== null &&
      !existing &&
      product.stock_qty <= 0
    ) {
      alert("Món này đã hết hàng.");
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
        stock_qty: product.stock_qty
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

    if (
      delta > 0 &&
      item.stock_qty !== null &&
      item.qty >= item.stock_qty
    ) {
      alert("Món này chỉ còn " + item.stock_qty + " phần.");
      return;
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
        alert("Vui lòng thêm sản phẩm vào giỏ hàng.");
        return;
      }

      const customerName = document
        .getElementById("customerName")
        .value.trim();

      const payment = document.querySelector(
        'input[name="payment"]:checked'
      ).value;

      const note =
        document.getElementById("customerNote").value.trim() || "Không có";

      if (!customerName) {
        alert("Vui lòng nhập tên khách.");
        return;
      }

      if (deliveryMethod.value === "pickup") {
        if (!pickupDate.value || !pickupTime.value) {
          alert("Vui lòng chọn ngày và giờ pick up.");
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
            "• " +
            item.qty +
            " x " +
            item.name +
            " — $" +
            money(item.price * item.qty)
          );
        })
        .join("\n");

      let text =
        "ĐƠN HÀNG — CÓ CÁI TIỆM\n\n" +
        "Khách: " +
        customerName +
        "\n\n" +
        lines +
        "\n\n" +
        "Tổng sản phẩm: $" +
        money(totalPrice) +
        "\n" +
        "Nhận hàng: " +
        deliveryLabels[deliveryMethod.value];

      if (deliveryMethod.value === "pickup") {
        text +=
          "\nNgày pick up: " +
          pickupDate.value +
          "\nGiờ pick up: " +
          pickupTime.value;
      } else {
        text +=
          "\nTên người nhận: " +
          recipientName.value.trim() +
          "\nSĐT: " +
          recipientPhone.value.trim() +
          "\nĐịa chỉ: " +
          shippingAddress.value.trim();
      }

      text +=
        "\nThanh toán: " + payment + "\nGhi chú: " + note;

      if (payment === "PayID") {
        text += "\n\nPayID: " + PAYID;
      }

      orderBox.textContent = text;
      orderBox.style.display = "block";
      orderHelp.style.display = "block";
      copyOrderBtn.style.display = "block";
      messengerBtn.style.display = "block";

      await loadProducts();
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
    window.open(
      "https://m.me/" + encodeURIComponent(MESSENGER_PAGE),
      "_blank"
    );
  });

  const today = new Date();
  const yyyy = today.getFullYear();
  const mm = String(today.getMonth() + 1).padStart(2, "0");
  const dd = String(today.getDate()).padStart(2, "0");
  pickupDate.min = yyyy + "-" + mm + "-" + dd;

  loadProducts().then(function () {
    renderProducts("all");
  });

  updateCart();
  syncShippingFields();
});