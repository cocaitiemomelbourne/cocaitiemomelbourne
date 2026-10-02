(function () {
  function isEnglish() {
    return window.CCT_LANG === "en";
  }

  function clearValue(id) {
    var el = document.getElementById(id);
    if (!el) return;
    if (el.type === "checkbox" || el.type === "radio") return;
    el.value = "";
  }

  function resetPaymentToCash() {
    var cash = document.querySelector('input[name="payment"][value="Cash"], input[name="paymentMethod"][value="Cash"], input[type="radio"][value="Cash"]');
    if (!cash) return;
    cash.checked = true;
    cash.dispatchEvent(new Event("change", { bubbles: true }));
  }

  function resetFulfilment() {
    var deliveryMethod = document.getElementById("deliveryMethod");
    if (!deliveryMethod) return;
    deliveryMethod.value = "pickup";
    deliveryMethod.dispatchEvent(new Event("change", { bubbles: true }));
  }

  window.CCT_resetAfterOrderV23 = function () {
    var api = window.CCT_API;
    if (!api) return;

    var cart = api.getCart();
    if (Array.isArray(cart)) cart.splice(0, cart.length);
    api.updateCart();

    [
      "customerName",
      "customerPhone",
      "contactEmail",
      "pickupDate",
      "pickupTime",
      "recipientName",
      "shippingAddress",
      "customerNote",
      "note",
      "pickupPhone",
      "recipientPhone"
    ].forEach(clearValue);

    var address = document.getElementById("shippingAddress");
    if (address) address.dispatchEvent(new Event("input", { bubbles: true }));

    resetFulfilment();
    resetPaymentToCash();

    var makeOrderBtn = document.getElementById("makeOrderBtn");
    if (makeOrderBtn) {
      makeOrderBtn.disabled = false;
      makeOrderBtn.textContent = isEnglish() ? "Create new order" : "Tạo đơn mới";
    }

    var cartCount = document.getElementById("cartCount");
    if (cartCount) cartCount.textContent = "0";
    var mobileCartCount = document.getElementById("mobileCartCount");
    if (mobileCartCount) mobileCartCount.textContent = "0";
  };
})();
