document.addEventListener("DOMContentLoaded", function () {
  const productGrid = document.getElementById("productGrid");
  const cartCount = document.getElementById("cartCount");

  if (!productGrid) return;

  function getQty(productId) {
    const cart = Array.isArray(window.CCT_CART) ? window.CCT_CART : [];
    return cart
      .filter(function (item) { return Number(item.id) === Number(productId); })
      .reduce(function (sum, item) { return sum + Number(item.qty || 0); }, 0);
  }

  function restoreCard(card) {
    const control = card.querySelector(".card-qty-control");
    if (!control) {
      card.classList.remove("selected");
      return;
    }

    const plus = control.querySelector("[data-add-index]");
    if (plus) {
      plus.className = "add-btn";
      plus.textContent = "+";
      plus.removeAttribute("aria-label");
      control.parentNode.appendChild(plus);
    }

    control.remove();
    card.classList.remove("selected");
  }

  function decorateCards() {
    const products = Array.isArray(window.CCT_PRODUCTS) ? window.CCT_PRODUCTS : [];
    if (!products.length) return;

    productGrid.querySelectorAll(".product-card").forEach(function (card) {
      let plus = card.querySelector("[data-add-index]");
      const existingControl = card.querySelector(".card-qty-control");

      if (!plus && existingControl) {
        plus = existingControl.querySelector("[data-add-index]");
      }

      if (!plus) return;

      const index = Number(plus.dataset.addIndex);
      const product = products[index];
      if (!product) return;

      const qty = getQty(product.id);

      if (qty <= 0) {
        restoreCard(card);
        return;
      }

      card.classList.add("selected");

      let control = card.querySelector(".card-qty-control");

      if (!control) {
        control = document.createElement("div");
        control.className = "card-qty-control";

        const minus = document.createElement("button");
        minus.type = "button";
        minus.className = "card-qty-btn";
        minus.dataset.cardMinusId = String(product.id);
        minus.textContent = "−";
        minus.setAttribute("aria-label", "Giảm số lượng");

        const center = document.createElement("div");
        center.className = "card-qty-center";
        center.innerHTML = '<span class="card-selected-label"></span><strong class="card-selected-qty"></strong>';

        plus.className = "card-qty-btn";
        plus.setAttribute("aria-label", "Tăng số lượng");

        control.appendChild(minus);
        control.appendChild(center);
        control.appendChild(plus);

        const bottom = card.querySelector(".product-bottom");
        if (bottom) bottom.appendChild(control);
      }

      const qtyNode = control.querySelector(".card-selected-qty");
      if (qtyNode) qtyNode.textContent = String(qty);
      const labelNode = control.querySelector(".card-selected-label");
      if (labelNode) labelNode.textContent = window.CCT_LANG === "en" ? "Selected" : "Đã chọn";
    });
  }

  productGrid.addEventListener("click", function (event) {
    const minus = event.target.closest("[data-card-minus-id]");
    if (!minus) return;

    event.preventDefault();
    event.stopPropagation();

    const productId = Number(minus.dataset.cardMinusId);
    const cart = Array.isArray(window.CCT_CART) ? window.CCT_CART : [];

    for (let i = cart.length - 1; i >= 0; i -= 1) {
      if (Number(cart[i].id) === productId) {
        cart[i].qty -= 1;
        if (cart[i].qty <= 0) cart.splice(i, 1);
        break;
      }
    }

    if (typeof window.CCT_resetOrderReservation === "function") {
      window.CCT_resetOrderReservation();
    }

    if (typeof window.CCT_updateCart === "function") {
      window.CCT_updateCart();
    }

    requestAnimationFrame(decorateCards);
  });

  const gridObserver = new MutationObserver(function () {
    requestAnimationFrame(decorateCards);
  });

  gridObserver.observe(productGrid, {
    childList: true,
    subtree: true
  });

  if (cartCount) {
    const cartObserver = new MutationObserver(function () {
      requestAnimationFrame(decorateCards);
    });

    cartObserver.observe(cartCount, {
      childList: true,
      characterData: true,
      subtree: true
    });
  }

  requestAnimationFrame(decorateCards);
});