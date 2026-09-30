document.addEventListener("DOMContentLoaded", function () {
  var api = window.CCT_API;
  var successBox = document.getElementById("orderSuccess");
  var makeOrderBtn = document.getElementById("makeOrderBtn");
  if (!api || !successBox || !makeOrderBtn) return;

  var handledSignature = "";

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
    if (cash) {
      cash.checked = true;
      cash.dispatchEvent(new Event("change", { bubbles: true }));
    }
  }

  function resetFulfilment() {
    var deliveryMethod = document.getElementById("deliveryMethod");
    if (deliveryMethod) {
      deliveryMethod.value = "pickup";
      deliveryMethod.dispatchEvent(new Event("change", { bubbles: true }));
    }
  }

  function clearCustomerFields() {
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
  }

  function resetAfterSuccessfulOrder() {
    var signature = successBox.textContent.trim();
    if (!signature || signature === handledSignature) return;
    if (getComputedStyle(successBox).display === "none") return;

    handledSignature = signature;

    var cart = api.getCart();
    if (Array.isArray(cart)) cart.splice(0, cart.length);
    api.updateCart();
    clearCustomerFields();

    makeOrderBtn.disabled = false;
    makeOrderBtn.textContent = isEnglish() ? "Create new order" : "Tạo đơn mới";

    var cartCount = document.getElementById("cartCount");
    if (cartCount) cartCount.textContent = "0";
    var mobileCartCount = document.getElementById("mobileCartCount");
    if (mobileCartCount) mobileCartCount.textContent = "0";
  }

  new MutationObserver(function () {
    setTimeout(resetAfterSuccessfulOrder, 30);
  }).observe(successBox, { childList: true, subtree: true, attributes: true, attributeFilter: ["style", "class"] });

  document.querySelectorAll("[data-lang]").forEach(function (button) {
    button.addEventListener("click", function () {
      setTimeout(function () {
        if (handledSignature && getComputedStyle(successBox).display !== "none") {
          makeOrderBtn.disabled = false;
          makeOrderBtn.textContent = isEnglish() ? "Create new order" : "Tạo đơn mới";
        }
      }, 120);
    });
  });
});
