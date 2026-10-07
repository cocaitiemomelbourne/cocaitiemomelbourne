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
  var deliveryDateWrap = null;
  var deliveryDateSelect = null;
  window.CCT_deliveryMatch = null;

  function isEn() { return window.CCT_LANG === "en"; }
  function money(v) { return Number(v || 0).toFixed(2).replace(/\.00$/, ""); }
  function displayDate(v) { return String(v || "").replace(/^(\d{4})-(\d{2})-(\d{2})$/, function(_,y,m,d){return d+"/"+m+"/"+y.slice(-2);}); }
  function isoLocalDate(date) {
    var y=date.getFullYear(), m=String(date.getMonth()+1).padStart(2,"0"), d=String(date.getDate()).padStart(2,"0");
    return y+"-"+m+"-"+d;
  }
  function deliveryDateLabel(date) {
    var daysVi=["Chủ nhật","Thứ 2","Thứ 3","Thứ 4","Thứ 5","Thứ 6","Thứ 7"];
    var daysEn=["Sun","Mon","Tue","Wed","Thu","Fri","Sat"];
    var dd=String(date.getDate()).padStart(2,"0");
    var mm=String(date.getMonth()+1).padStart(2,"0");
    var yyyy=date.getFullYear();
    return (isEn()?daysEn[date.getDay()]:daysVi[date.getDay()])+", "+dd+"/"+mm+"/"+yyyy;
  }
  function ensureDeliveryDateField() {
    if (deliveryDateWrap && deliveryDateWrap.isConnected) return;
    var shippingFields=document.getElementById("shippingFields");
    if(!shippingFields) return;
    deliveryDateWrap=document.createElement("div");
    deliveryDateWrap.id="deliveryDateFieldV29";
    var label=document.createElement("label");
    label.htmlFor="deliveryDateV29";
    label.id="deliveryDateLabelV29";
    deliveryDateSelect=document.createElement("select");
    deliveryDateSelect.id="deliveryDateV29";
    deliveryDateSelect.required=true;
    deliveryDateWrap.appendChild(label);
    deliveryDateWrap.appendChild(deliveryDateSelect);
    var addressLabel=shippingFields.querySelector('label[for="shippingAddress"]');
    if(addressLabel) shippingFields.insertBefore(deliveryDateWrap,addressLabel);
    else shippingFields.appendChild(deliveryDateWrap);
    populateDeliveryDates();
    syncDeliveryDateVisibility();
  }
  function populateDeliveryDates() {
    if(!deliveryDateSelect) return;
    var current=deliveryDateSelect.value;
    var options=['<option value="">'+(isEn()?'Select delivery date':'Chọn ngày delivery')+'</option>'];
    var today=new Date(); today.setHours(0,0,0,0);
    var count=0;
    for(var i=0;i<42 && count<12;i++){
      var d=new Date(today); d.setDate(today.getDate()+i);
      var day=d.getDay();
      if(day===5 || day===6){
        var iso=isoLocalDate(d);
        options.push('<option value="'+iso+'">'+deliveryDateLabel(d)+'</option>');
        count++;
      }
    }
    deliveryDateSelect.innerHTML=options.join("");
    if(current && Array.from(deliveryDateSelect.options).some(function(o){return o.value===current;})) deliveryDateSelect.value=current;
    var label=document.getElementById("deliveryDateLabelV29");
    if(label) label.textContent=isEn()?"Delivery date (Friday or Saturday)":"Ngày delivery (Thứ 6 hoặc Thứ 7)";
  }
  function syncDeliveryDateVisibility() {
    ensureDeliveryDateField();
    if(!deliveryDateWrap) return;
    var isDelivery=deliveryMethod.value==="delivery";
    deliveryDateWrap.style.display=isDelivery?"block":"none";
    if(deliveryDateSelect) {
      deliveryDateSelect.required=isDelivery;
      if(!isDelivery) deliveryDateSelect.value="";
    }
  }
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
    var deliveryDate = String((document.getElementById("deliveryDateV29") || {}).value || "").trim();
    var payment = String(ctx.payment || ((document.querySelector('input[name="payment"]:checked') || {}).value || "")).trim();
    var lines = [];

    lines.push(customerName);
    if (ctx.hasPreorder) lines.push(en ? "⚠ PRE-ORDER ITEM(S) – ESTIMATED 7–14 DAYS" : "⚠ HÀNG ĐẶT TRƯỚC – DỰ KIẾN 7–14 NGÀY");
    cart.forEach(function (item) {
      var optionText = item.option_text ? " (" + item.option_text + ")" : "";
      lines.push(Number(item.qty || 0) + " x " + String(item.name || "") + optionText + " $" + money(Number(item.price || 0) * Number(item.qty || 0)));
    });
    var pending = method === "auspost" || (method === "delivery" && !match);
    lines.push((pending ? (en ? "Provisional total: $" : "Tạm tính: $") : (en ? "Total: $" : "Tổng: $")) + money(total));

    if (method === "pickup") {
      lines.push(en ? "Fulfilment: Pick up Springvale" : "Nhận hàng: Pick up Springvale");
      if (pickupDate) lines.push((en ? "Pickup date: " : "Ngày pick up: ") + displayDate(pickupDate));
      if (pickupTime) lines.push((en ? "Pickup time: " : "Giờ pick up: ") + pickupTime.slice(0,5));
    } else if (method === "delivery") {
      lines.push(en ? "Fulfilment: Melbourne delivery" : "Nhận hàng: Delivery Melbourne");
      if (deliveryDate) lines.push((en ? "Delivery date: " : "Ngày delivery: ") + displayDate(deliveryDate));
      lines.push((en ? "Delivery fee: " : "Phí giao hàng: ") + (match ? "$" + money(fee) + " – " + match.suburb : (en ? "Quote pending" : "Chờ báo giá")));
      lines.push((en ? "Address: " : "Địa chỉ: ") + address);
    } else {
      lines.push(en ? "Fulfilment: AusPost (quote after order)" : "Nhận hàng: AusPost (báo giá sau khi tạo đơn)");
      if (recipient) lines.push((en ? "Recipient: " : "Tên người nhận: ") + recipient);
      lines.push((en ? "Address: " : "Địa chỉ: ") + address);
    }

    lines.push((en ? "Phone: " : "Sđt: ") + phone);
    if (email) lines.push((en ? "Contact email: " : "Email liên hệ: ") + email);
    lines.push((en ? "Note: " : "Ghi chú: ") + (note === "Không có" || note === "None" ? "" : note));
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
    var deliveryDate = String((document.getElementById("deliveryDateV29") || {}).value || "").trim();
    try {
      var response = await fetch(SUPABASE_URL + "/rest/v1/rpc/save_order_delivery_pricing_v2", {
        method: "POST",
        headers: { apikey: k, Authorization: "Bearer " + k, "Content-Type": "application/json" },
        body: JSON.stringify({
          p_order_token: orderToken,
          p_fulfilment_method: method,
          p_shipping_address: method === "pickup" ? "" : addressInput.value.trim(),
          p_delivery_date: method === "delivery" && deliveryDate ? deliveryDate : null,
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
  deliveryMethod.addEventListener("change", function(){ refreshMatch(); syncDeliveryDateVisibility(); });
  document.querySelectorAll("[data-lang]").forEach(function (button) {
    button.addEventListener("click", function () { setTimeout(function(){ setQuoteUI(); populateDeliveryDates(); }, 120); });
  });

  var makeOrderBtn=document.getElementById("makeOrderBtn");
  if(makeOrderBtn){
    makeOrderBtn.addEventListener("click",function(event){
      if(deliveryMethod.value!=="delivery") return;
      ensureDeliveryDateField();
      if(!deliveryDateSelect || !deliveryDateSelect.value){
        event.preventDefault();
        event.stopImmediatePropagation();
        alert(isEn()?"Please select a delivery date. Delivery is available on Fridays and Saturdays only.":"Vui lòng chọn ngày delivery. Tiệm chỉ giao hàng vào Thứ 6 và Thứ 7 hằng tuần.");
        if(deliveryDateSelect) deliveryDateSelect.focus();
      }
    },true);
  }
  if (cartCount) new MutationObserver(function () { setTimeout(setQuoteUI, 20); }).observe(cartCount, { childList: true, characterData: true, subtree: true });

  ensureDeliveryDateField();
  syncDeliveryDateVisibility();
  setQuoteUI();
  loadRates();
});
