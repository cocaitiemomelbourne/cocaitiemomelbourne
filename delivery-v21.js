document.addEventListener("DOMContentLoaded", function () {
  var api = window.CCT_API;
  var addressInput = document.getElementById("shippingAddress");
  var deliveryMethod = document.getElementById("deliveryMethod");
  var cartTotal = document.getElementById("cartTotal");
  var cartCount = document.getElementById("cartCount");
  if (!api || !addressInput || !deliveryMethod || !cartTotal) return;

  var SUPABASE_URL = "https://eswrqkhsvlqndjbrgsqo.supabase.co";
  var rates = [];
  var key = null;
  var quoteRow = null;
  var quoteTimer = null;
  window.CCT_deliveryMatch = null;

  function isEn() { return window.CCT_LANG === "en"; }
  function money(v) { return Number(v || 0).toFixed(2).replace(/\.00$/, ""); }
  function normalize(v) {
    return String(v || "")
      .normalize("NFD")
      .replace(/[\u0300-\u036f]/g, "")
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, " ")
      .trim();
  }
  function getKey() {
    if (key) return key;
    var source = Array.from(document.scripts).map(function (s) { return s.textContent || ""; }).join("\n");
    var m = source.match(/sb_publishable_[A-Za-z0-9_-]+/);
    key = m ? m[0] : null;
    return key;
  }
  function subtotal() {
    return api.getCart().reduce(function (sum, item) {
      return sum + Number(item.price || 0) * Number(item.qty || 0);
    }, 0);
  }
  function escapeHtml(v) {
    return String(v == null ? "" : v).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }
  function ensureQuoteRow() {
    if (quoteRow && quoteRow.isConnected) return quoteRow;
    var totalRow = document.querySelector(".total-row");
    if (!totalRow) return null;
    quoteRow = document.createElement("div");
    quoteRow.id = "deliveryQuoteV21";
    quoteRow.style.cssText = "display:none;justify-content:space-between;gap:12px;padding:8px 0 2px;font-size:13px;font-weight:800;color:#6f5b49";
    totalRow.insertAdjacentElement("afterend", quoteRow);
    return quoteRow;
  }
  function setQuoteUI() {
    var row = ensureQuoteRow();
    var method = deliveryMethod.value;
    var sub = subtotal();
    var match = window.CCT_deliveryMatch;
    var fee = method === "delivery" && match ? Number(match.fee || 0) : 0;
    var total = sub + fee;
    var expected = money(total);
    if (cartTotal.textContent !== expected) cartTotal.textContent = expected;
    var pending = method === "auspost" || (method === "delivery" && !match);
    var label = document.querySelector(".total-row > span");
    var labelText = pending ? (isEn() ? "Provisional total" : "Tạm tính") : (isEn() ? "Total" : "Tổng");
    if (label && label.textContent !== labelText) label.textContent = labelText;

    if (!row) return;
    if (method === "pickup") {
      row.style.display = "none";
      return;
    }
    row.style.display = "flex";
    if (method === "delivery" && match) {
      row.innerHTML = '<span>' + (isEn() ? 'Delivery fee' : 'Phí giao hàng') +
        ' <span style="font-weight:600">(' + escapeHtml(match.suburb) + ')</span></span><strong>$' + money(match.fee) + '</strong>';
    } else {
      row.innerHTML = '<span>' + (isEn() ? 'Delivery fee' : 'Phí giao hàng') + '</span><strong>' +
        (isEn() ? 'Quote pending' : 'Chờ báo giá') + '</strong>';
    }
  }
  function addressHasToken(addressNorm, tokenNorm) {
    if (!tokenNorm) return false;
    return (" " + addressNorm + " ").indexOf(" " + tokenNorm + " ") !== -1;
  }
  function findRate(address) {
    var a = normalize(address);
    if (!a) return null;
    var postcodeMatch = String(address || "").match(/\b(\d{4})\b/g) || [];
    var candidates = [];

    rates.forEach(function (rate) {
      var labels = [];
      (Array.isArray(rate.aliases) ? rate.aliases : []).forEach(function (x) { if (x) labels.push(String(x)); });
      if (rate.suburb) labels.push(String(rate.suburb));

      labels.forEach(function (label) {
        var n = normalize(label);
        if (!n) return;
        var matched = false;
        if (/^\d{4}$/.test(n)) {
          matched = postcodeMatch.indexOf(n) !== -1;
        } else if (normalize(rate.suburb) === "melbourne") {
          matched = /\b300[0-6]\b/.test(String(address || ""));
        } else {
          matched = addressHasToken(a, n);
        }
        if (matched) candidates.push({ rate: rate, score: n.length });
      });
    });

    if (!candidates.length) return null;
    candidates.sort(function (x, y) {
      if (y.score !== x.score) return y.score - x.score;
      return Number(x.rate.sort_order || 9999) - Number(y.rate.sort_order || 9999);
    });
    return candidates[0].rate;
  }
  function refreshMatch() {
    window.CCT_deliveryMatch = deliveryMethod.value === "delivery" ? findRate(addressInput.value) : null;
    setQuoteUI();
  }
  async function loadRates() {
    var k = getKey();
    if (!k) { setQuoteUI(); return; }
    try {
      var response = await fetch(
        SUPABASE_URL + "/rest/v1/delivery_rates?select=zone,suburb,fee,aliases,sort_order&is_active=eq.true&order=sort_order.asc",
        { headers: { apikey: k, Authorization: "Bearer " + k } }
      );
      if (!response.ok) throw new Error("delivery_rates");
      var data = await response.json();
      rates = Array.isArray(data) ? data : [];
      refreshMatch();
    } catch (error) {
      console.error(error);
      rates = [];
      window.CCT_deliveryMatch = null;
      setQuoteUI();
    }
  }

  window.CCT_finalizeOrderTextV21 = function (ctx) {
    ctx = ctx || {};
    var en = isEn();
    var cart = api.getCart();
    var sub = Number(ctx.subtotal != null ? ctx.subtotal : subtotal());
    var method = deliveryMethod.value;
    var match = method === "delivery" ? window.CCT_deliveryMatch : null;
    var fee = match ? Number(match.fee || 0) : 0;
    var total = sub + fee;
    var customerName = String(ctx.customerName || (document.getElementById("customerName") || {}).value || "").trim();
    var phone = String(ctx.confirmationPhone || (document.getElementById("customerPhone") || {}).value || "").trim();
    var email = String((document.getElementById("contactEmail") || {}).value || "").trim();
    var note = String(ctx.note || (document.getElementById("customerNote") || {}).value || "").trim();
    var recipient = String((document.getElementById("recipientName") || {}).value || "").trim();
    var address = String(addressInput.value || "").trim();
    var pickupDate = String((document.getElementById("pickupDate") || {}).value || "").trim();
    var pickupTime = String((document.getElementById("pickupTime") || {}).value || "").trim();
    var payment = String(ctx.payment || ((document.querySelector('input[name="payment"]:checked') || {}).value || "")).trim();
    var lines = [];

    lines.push((en ? "Order code: " : "Mã đơn: ") + String(ctx.orderCode || ""));
    if (ctx.hasPreorder) lines.push(en ? "⚠ PRE-ORDER ITEM(S) – ESTIMATED 7–14 DAYS" : "⚠ HÀNG ĐẶT TRƯỚC – DỰ KIẾN 7–14 NGÀY");
    lines.push(customerName);
    cart.forEach(function (item) {
      var optionText = item.option_text ? " (" + item.option_text + ")" : "";
      lines.push(Number(item.qty || 0) + " x " + String(item.name || "") + optionText + " $" + money(Number(item.price || 0) * Number(item.qty || 0)));
    });
    lines.push((en ? "Items subtotal: $" : "Tiền món: $") + money(sub));

    if (method === "pickup") {
      lines.push(en ? "Fulfilment: Pick up Springvale" : "Nhận hàng: Pick up Springvale");
      if (pickupDate) lines.push((en ? "Pickup date: " : "Ngày pick up: ") + pickupDate);
      if (pickupTime) lines.push((en ? "Pickup time: " : "Giờ pick up: ") + pickupTime);
    } else if (method === "delivery") {
      lines.push(en ? "Fulfilment: Melbourne delivery" : "Nhận hàng: Delivery Melbourne");
      lines.push((en ? "Delivery fee: " : "Phí giao hàng: ") + (match ? "$" + money(fee) + " – " + match.suburb : (en ? "Quote pending" : "Chờ báo giá")));
      lines.push((en ? "Address: " : "Địa chỉ: ") + address);
    } else {
      lines.push(en ? "Fulfilment: AusPost (quote after order)" : "Nhận hàng: AusPost (báo giá sau khi tạo đơn)");
      if (recipient) lines.push((en ? "Recipient: " : "Tên người nhận: ") + recipient);
      lines.push((en ? "Address: " : "Địa chỉ: ") + address);
    }

    lines.push((en ? "Phone: " : "SĐT: ") + phone);
    if (email) lines.push((en ? "Contact email: " : "Email liên hệ: ") + email);
    lines.push((en ? "Payment: " : "Thanh toán: ") + payment);
    lines.push((en ? "Note: " : "Ghi chú: ") + (note || (en ? "None" : "Không có")));
    var pending = method === "auspost" || (method === "delivery" && !match);
    lines.push((pending ? (en ? "Provisional total: $" : "Tạm tính: $") : (en ? "Total: $" : "Tổng: $")) + money(total));
    return lines.join("\n");
  };

  window.CCT_saveDeliveryPricingV21 = async function (orderToken, subtotalValue) {
    var k = getKey();
    if (!k || !orderToken) return false;
    var method = deliveryMethod.value;
    var match = method === "delivery" ? window.CCT_deliveryMatch : null;
    var sub = Number(subtotalValue != null ? subtotalValue : subtotal());
    var fee = method === "pickup" ? 0 : (match ? Number(match.fee || 0) : null);
    var total = fee == null ? null : sub + fee;
    try {
      var response = await fetch(SUPABASE_URL + "/rest/v1/rpc/save_order_delivery_pricing_v1", {
        method: "POST",
        headers: { apikey: k, Authorization: "Bearer " + k, "Content-Type": "application/json" },
        body: JSON.stringify({
          p_order_token: orderToken,
          p_fulfilment_method: method,
          p_shipping_address: method === "pickup" ? "" : addressInput.value.trim(),
          p_subtotal: sub,
          p_delivery_fee: fee,
          p_total: total,
          p_language: isEn() ? "en" : "vi"
        })
      });
      return response.ok;
    } catch (error) {
      console.error(error);
      return false;
    }
  };

  addressInput.addEventListener("input", function () {
    clearTimeout(quoteTimer);
    quoteTimer = setTimeout(refreshMatch, 80);
  });
  addressInput.addEventListener("change", refreshMatch);
  deliveryMethod.addEventListener("change", refreshMatch);
  document.querySelectorAll("[data-lang]").forEach(function (button) {
    button.addEventListener("click", function () { setTimeout(setQuoteUI, 120); });
  });
  if (cartCount) new MutationObserver(function () { setTimeout(setQuoteUI, 20); }).observe(cartCount, { childList: true, characterData: true, subtree: true });

  setQuoteUI();
  loadRates();
});
