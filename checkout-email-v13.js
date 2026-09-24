document.addEventListener("DOMContentLoaded", function () {
  var deliveryMethod = document.getElementById("deliveryMethod");
  var customerName = document.getElementById("customerName");
  var contactEmail = document.getElementById("contactEmail");
  var recipientNameField = document.getElementById("recipientNameField");
  var recipientName = document.getElementById("recipientName");
  var customerNote = document.getElementById("customerNote");
  var makeOrderBtn = document.getElementById("makeOrderBtn");
  var orderBox = document.getElementById("orderBox");
  var orderHelp = document.getElementById("orderHelp");
  var copyBtn = document.getElementById("copyOrderBtn");
  var messengerBtn = document.getElementById("messengerBtn");
  var payidPanel = document.getElementById("payidPanel");
  var payidTitle = document.getElementById("payidPanelTitle");

  function isEnglish() {
    return window.CCT_LANG === "en";
  }

  function hideLegacySendOptions() {
    if (copyBtn) copyBtn.style.setProperty("display", "none", "important");
    if (messengerBtn) messengerBtn.style.setProperty("display", "none", "important");
    if (orderHelp && orderHelp.style.display !== "none") {
      orderHelp.innerHTML = isEnglish()
        ? '<strong>Send order by Email</strong><div class="send-option">Tap the button below to send your order directly to the shop and wait for confirmation.</div>'
        : '<strong>Gửi đơn qua Email</strong><div class="send-option">Bấm nút bên dưới để gửi đơn trực tiếp cho Tiệm và chờ xác nhận.</div>';
    }
  }

  function syncContactLabels() {
    var emailLabel = document.querySelector('label[for="contactEmail"]');
    if (emailLabel) {
      emailLabel.innerHTML = isEnglish()
        ? 'Contact email <span class="optional-text">(optional)</span>'
        : 'Email liên hệ <span class="optional-text">(không bắt buộc)</span>';
    }
    if (contactEmail) contactEmail.placeholder = "email@example.com";
    if (payidTitle) {
      payidTitle.textContent = isEnglish()
        ? "PayID / bank transfer details"
        : "Thông tin thanh toán PayID / chuyển khoản";
    }
  }

  function syncFulfilment() {
    if (!deliveryMethod || !recipientNameField) return;
    var method = deliveryMethod.value;
    recipientNameField.style.display = method === "auspost" ? "block" : "none";

    if (method === "delivery" && recipientName && customerName) {
      recipientName.value = customerName.value.trim();
    }
    if (method === "pickup" && recipientName) {
      recipientName.value = "";
    }
  }

  function syncPayment() {
    if (!payidPanel) return;
    var selected = document.querySelector('input[name="payment"]:checked');
    payidPanel.classList.toggle("show", !!selected && selected.value === "PayID");
  }

  function validEmail(value) {
    return !value || /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value);
  }

  function prepareForCreate(event) {
    var email = contactEmail ? contactEmail.value.trim() : "";
    if (!validEmail(email)) {
      event.preventDefault();
      event.stopImmediatePropagation();
      alert(isEnglish() ? "Please enter a valid contact email address." : "Email liên hệ chưa đúng định dạng.");
      contactEmail.focus();
      return;
    }

    if (deliveryMethod && deliveryMethod.value === "delivery" && recipientName && customerName) {
      recipientName.value = customerName.value.trim() || (isEnglish() ? "Customer" : "Khách");
    }

    if (email && customerNote) {
      var original = customerNote.value;
      var prefix = (isEnglish() ? "Contact email: " : "Email liên hệ: ") + email + " | ";
      customerNote.value = prefix + (original.trim() || (isEnglish() ? "None" : "Không có"));
      setTimeout(function () {
        customerNote.value = original;
      }, 50);
    }
  }

  function cleanOrderText() {
    if (!orderBox || !orderBox.textContent.trim()) return;

    var lines = orderBox.textContent.split(/\r?\n/);
    var method = deliveryMethod ? deliveryMethod.value : "";

    if (method === "delivery") {
      lines = lines.filter(function (line) {
        return !/^(Tên người nhận|Recipient):/i.test(line.trim());
      });
    }

    var out = [];
    lines.forEach(function (line) {
      var m = line.match(/^(Ghi chú|Note):\s*(Email liên hệ|Contact email):\s*([^|]+)\|\s*(.*)$/i);
      if (m) {
        out.push((isEnglish() ? "Contact email: " : "Email liên hệ: ") + m[3].trim());
        out.push((isEnglish() ? "Note: " : "Ghi chú: ") + (m[4].trim() || (isEnglish() ? "None" : "Không có")));
      } else {
        out.push(line);
      }
    });

    var cleaned = out.join("\n");
    if (cleaned !== orderBox.textContent) orderBox.textContent = cleaned;
    hideLegacySendOptions();
  }

  if (deliveryMethod) deliveryMethod.addEventListener("change", syncFulfilment);
  if (customerName) customerName.addEventListener("input", function () {
    if (deliveryMethod && deliveryMethod.value === "delivery" && recipientName) {
      recipientName.value = customerName.value.trim();
    }
  });

  document.querySelectorAll('input[name="payment"]').forEach(function (radio) {
    radio.addEventListener("change", syncPayment);
  });

  if (makeOrderBtn) makeOrderBtn.addEventListener("click", prepareForCreate, true);

  if (orderBox) {
    new MutationObserver(function () {
      setTimeout(cleanOrderText, 0);
    }).observe(orderBox, {childList:true,characterData:true,subtree:true});
  }

  if (orderHelp) {
    new MutationObserver(hideLegacySendOptions).observe(orderHelp, {childList:true,subtree:true});
  }

  document.querySelectorAll(".language-btn").forEach(function (btn) {
    btn.addEventListener("click", function () {
      setTimeout(function () {
        syncContactLabels();
        hideLegacySendOptions();
      }, 20);
    });
  });

  var nativeAlert = window.alert;
  window.alert = function (message) {
    var text = String(message == null ? "" : message);
    text = text.replace("Please try again or use Messenger.", "Please try again.");
    text = text.replace("Vui lòng thử lại hoặc gửi đơn qua Messenger.", "Vui lòng thử lại.");
    return nativeAlert.call(window, text);
  };

  syncFulfilment();
  syncPayment();
  syncContactLabels();
  hideLegacySendOptions();
});