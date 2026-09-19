document.addEventListener("DOMContentLoaded", function () {
  const PRODUCTS = [
    { name: "Ly Sứa Single", price: 20, category: "sua", emoji: "🪼", description: "Chọn 1 loại sứa + 1 loại sốt Thái hoặc Mắm Nhĩ." },
    { name: "Ly Sứa Combo", price: 32, category: "sua", emoji: "🥗", description: "Mix 5 loại sứa random, kèm Sốt Thái & Mắm Nhĩ." },
    { name: "Bánh Tráng Xì Ke 100g", price: 6, category: "banhtrang", emoji: "🌶️", description: "Đậm vị, cay nhẹ, ăn vui miệng." },
    { name: "Bánh Tráng Sate Tôm Hành 150g", price: 10, category: "banhtrang", emoji: "🦐", description: "Sate thơm, tôm hành đậm đà." },
    { name: "Bánh Tráng Bò Tỏi Chua Cay Duy Best 250g", price: 12, category: "banhtrang", emoji: "🥩", description: "Best seller — chua cay, thơm bò tỏi." },
    { name: "Bánh tráng Dẻo Tôm Sốt Me Bơ 70g", price: 5, category: "banhtrang", emoji: "🍋", description: "Dẻo mềm, chấm sốt me bơ béo chua ngọt." },
    { name: "Khô Gà Lá Chanh", price: 8, category: "kho", emoji: "🍗", description: "Thơm lá chanh, dai nhẹ, dễ ăn." },
    { name: "Khô Heo Cháy Tỏi", price: 10, category: "kho", emoji: "🥓", description: "Mặn ngọt vừa miệng, thơm tỏi." },
    { name: "Mực Xé Nước Dừa", price: 10, category: "kho", emoji: "🦑", description: "Dai ngọt, thơm vị nước dừa." },
    { name: "Cơm Cháy Chà Bông 500g", price: 18, category: "khac", emoji: "🍘", description: "Giòn rụm, nhiều chà bông." },
    { name: "Ghẹ Sữa Rim Giòn 130g", price: 15, category: "khac", emoji: "🦀", description: "Giòn, đậm vị." },
    { name: "Mít Sấy Giòn", price: 10, category: "khac", emoji: "🍈", description: "Giòn thơm, ăn vui miệng." },
    { name: "Bánh Gấu Mix 3 Vị 350g", price: 15, category: "khac", emoji: "🐻", description: "Mix 3 vị, giòn thơm." }
  ];

  const MESSENGER_PAGE = "cocaitiem.o.melbourne";
  const PAYID = "ĐIỀN PAYID CỦA TIỆM";

  const cart = [];

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

  function renderProducts(category) {
    const selected = category === "all"
      ? PRODUCTS
      : PRODUCTS.filter(function (product) {
          return product.category === category;
        });

    productGrid.innerHTML = selected.map(function (product) {
      const index = PRODUCTS.indexOf(product);
      return [
        '<div class="product-card">',
          '<div class="product-visual">', product.emoji, '</div>',
          '<div class="product-body">',
            '<h3>', escapeHtml(product.name), '</h3>',
            '<div class="product-desc">', escapeHtml(product.description), '</div>',
            '<div class="product-bottom">',
              '<span class="price">$', money(product.price), '</span>',
              '<button class="add-btn" type="button" data-add-index="', index, '">+</button>',
            '</div>',
          '</div>',
        '</div>'
      ].join("");
    }).join("");
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

    cartList.innerHTML = cart.map(function (item, index) {
      return [
        '<div class="cart-row">',
          '<div>',
            '<b>', escapeHtml(item.name), '</b><br>',
            '<small>$', money(item.price), ' × ', item.qty, '</small>',
          '</div>',
          '<div class="qty-btns">',
            '<button type="button" data-cart-index="', index, '" data-delta="-1">−</button> ',
            '<button type="button" data-cart-index="', index, '" data-delta="1">＋</button>',
          '</div>',
        '</div>'
      ].join("");
    }).join("");
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
    if (!button) return;

    const product = PRODUCTS[Number(button.dataset.addIndex)];
    const existing = cart.find(function (item) {
      return item.name === product.name;
    });

    if (existing) {
      existing.qty += 1;
    } else {
      cart.push({
        name: product.name,
        price: product.price,
        qty: 1
      });
    }

    updateCart();
  });

  cartList.addEventListener("click", function (event) {
    const button = event.target.closest("[data-cart-index]");
    if (!button) return;

    const index = Number(button.dataset.cartIndex);
    const delta = Number(button.dataset.delta);

    cart[index].qty += delta;

    if (cart[index].qty <= 0) {
      cart.splice(index, 1);
    }

    updateCart();
  });

  deliveryMethod.addEventListener("change", syncShippingFields);

  document.getElementById("makeOrderBtn").addEventListener("click", function () {
    if (cart.length === 0) {
      alert("Vui lòng thêm sản phẩm vào giỏ hàng.");
      return;
    }

    const customerName = document.getElementById("customerName").value.trim();
    const payment = document.querySelector('input[name="payment"]:checked').value;
    const note = document.getElementById("customerNote").value.trim() || "Không có";

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
      if (!recipientName.value.trim() || !recipientPhone.value.trim() || !shippingAddress.value.trim()) {
        alert("Vui lòng nhập tên người nhận, số điện thoại và địa chỉ nhận hàng.");
        return;
      }
    }

    const deliveryLabels = {
      pickup: "Pick up Springvale",
      delivery: "Delivery Melbourne",
      auspost: "AusPost"
    };

    const totalPrice = cart.reduce(function (sum, item) {
      return sum + item.price * item.qty;
    }, 0);

    const lines = cart.map(function (item) {
      return "• " + item.qty + " x " + item.name + " — $" + money(item.price * item.qty);
    }).join("\n");

    let text =
      "ĐƠN HÀNG — CÓ CÁI TIỆM\n\n" +
      "Khách: " + customerName + "\n\n" +
      lines + "\n\n" +
      "Tổng sản phẩm: $" + money(totalPrice) + "\n" +
      "Nhận hàng: " + deliveryLabels[deliveryMethod.value];

    if (deliveryMethod.value === "pickup") {
      text +=
        "\nNgày pick up: " + pickupDate.value +
        "\nGiờ pick up: " + pickupTime.value;
    } else {
      text +=
        "\nTên người nhận: " + recipientName.value.trim() +
        "\nSĐT: " + recipientPhone.value.trim() +
        "\nĐịa chỉ: " + shippingAddress.value.trim();
    }

    text +=
      "\nThanh toán: " + payment +
      "\nGhi chú: " + note;

    if (payment === "PayID") {
      text += "\n\nPayID: " + PAYID;
    }

    orderBox.textContent = text;
    orderBox.style.display = "block";
    orderHelp.style.display = "block";
    copyOrderBtn.style.display = "block";
    messengerBtn.style.display = "block";
  });

  copyOrderBtn.addEventListener("click", async function () {
    try {
      await navigator.clipboard.writeText(orderBox.textContent);
      alert("Đã copy đơn hàng. Tiếp theo bấm Gửi qua Messenger, dán nội dung đơn vào khung chat rồi bấm Send.");
    } catch (error) {
      alert("Trình duyệt không cho copy tự động. Vui lòng chọn nội dung đơn và copy thủ công.");
    }
  });

  messengerBtn.addEventListener("click", function () {
    window.open("https://m.me/" + encodeURIComponent(MESSENGER_PAGE), "_blank");
  });

  const today = new Date();
  const yyyy = today.getFullYear();
  const mm = String(today.getMonth() + 1).padStart(2, "0");
  const dd = String(today.getDate()).padStart(2, "0");
  pickupDate.min = yyyy + "-" + mm + "-" + dd;

  renderProducts("all");
  updateCart();
  syncShippingFields();
});