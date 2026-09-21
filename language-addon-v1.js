document.addEventListener("DOMContentLoaded", function () {
  const SUPABASE_URL = "https://eswrqkhsvlqndjbrgsqo.supabase.co";
  const SUPABASE_KEY = "sb_publishable_-6iIwPaZQRMkkWAROdfvxg_dmVB81E2";
  const api = window.CCT_API;
  if (!api) return;

  let currentLang = localStorage.getItem("cct_lang") === "en" ? "en" : "vi";
  window.CCT_LANG = currentLang;

  let productTranslations = new Map();
  let categoryTranslations = new Map();

  const text = {
    vi: {
      topbar:"Hàng có sẵn • Pick up Springvale • Delivery Melbourne • AusPost từ $12",
      subtitle:"Ăn vặt Melbourne",
      tagline:"Món ngon cho những ngày thêm vui ♡",
      note:"🛒 Order dễ dàng • Cash hoặc PayID",
      cart:"🛒 Giỏ hàng ",
      drawer:"Giỏ hàng",
      total:"Tổng",
      customer:"Tên khách",
      customerPh:"Tên của bạn",
      fulfilment:"Nhận hàng",
      pickupDate:"Chọn ngày pick up",
      pickupTime:"Chọn giờ pick up",
      phone:"Số điện thoại ",
      optional:"(không bắt buộc)",
      phoneNote:"Chỉ bắt buộc nếu bạn chọn gửi đơn qua Email.",
      recipient:"Tên người nhận",
      recipientPh:"Tên người nhận",
      address:"Địa chỉ nhận hàng",
      addressPh:"Số nhà, tên đường, suburb, postcode",
      payment:"Thanh toán",
      noteLabel:"Ghi chú",
      notePh:"Ví dụ: ít cay, gọi trước khi giao...",
      create:"Tạo đơn hàng",
      copy:"📋 Copy đơn hàng",
      messenger:"💬 Gửi qua Messenger @cocaitiem.o.melbourne",
      email:"✉️ Gửi đơn hàng qua Email",
      help:'<strong>Chọn 1 cách gửi đơn:</strong><div class="send-option"><strong>1. Gửi qua Messenger</strong><br>Copy đơn hàng → mở Messenger <strong>@cocaitiem.o.melbourne</strong> → Paste và Send.</div><div class="send-option"><strong>2. Gửi qua Email</strong><br>Gửi đơn trực tiếp cho Tiệm và chờ xác nhận qua số điện thoại.</div>'
    },
    en: {
      topbar:"In stock • Pick up Springvale • Melbourne delivery • AusPost from $12",
      subtitle:"Melbourne Vietnamese Snacks",
      tagline:"Tasty bites for brighter days ♡",
      note:"🛒 Easy ordering • Cash or PayID",
      cart:"🛒 Cart ",
      drawer:"Cart",
      total:"Total",
      customer:"Customer name",
      customerPh:"Your name",
      fulfilment:"Fulfilment",
      pickupDate:"Pickup date",
      pickupTime:"Pickup time",
      phone:"Phone number ",
      optional:"(optional)",
      phoneNote:"Only required if you choose to send the order by Email.",
      recipient:"Recipient name",
      recipientPh:"Recipient name",
      address:"Delivery address",
      addressPh:"Street, suburb, postcode",
      payment:"Payment",
      noteLabel:"Note",
      notePh:"E.g. mild spice, call before delivery...",
      create:"Create order",
      copy:"📋 Copy order",
      messenger:"💬 Send via Messenger @cocaitiem.o.melbourne",
      email:"✉️ Send order by Email",
      help:'<strong>Choose 1 way to send your order:</strong><div class="send-option"><strong>1. Send via Messenger</strong><br>Copy order → open Messenger <strong>@cocaitiem.o.melbourne</strong> → Paste and Send.</div><div class="send-option"><strong>2. Send by Email</strong><br>Send the order directly to the shop and wait for confirmation by phone.</div>'
    }
  };

  function headers() {
    return {
      apikey: SUPABASE_KEY,
      Authorization: "Bearer " + SUPABASE_KEY
    };
  }

  async function loadTranslations() {
    const productUrl =
      SUPABASE_URL +
      "/rest/v1/products?select=id,name,name_en,description,description_en,option_groups,option_groups_en&is_active=eq.true";
    const categoryUrl =
      SUPABASE_URL +
      "/rest/v1/product_categories?select=slug,label,label_en,is_active&is_active=eq.true";

    const responses = await Promise.all([
      fetch(productUrl, { headers: headers() }),
      fetch(categoryUrl, { headers: headers() })
    ]);

    if (!responses[0].ok || !responses[1].ok) {
      throw new Error("translation_load_failed");
    }

    const products = await responses[0].json();
    const categories = await responses[1].json();

    productTranslations = new Map(products.map(function (p) { return [Number(p.id), p]; }));
    categoryTranslations = new Map(categories.map(function (c) { return [c.slug, c]; }));
  }

  function translateOptions(options, translation, lang) {
    if (!Array.isArray(options) || !options.length || !translation) return options || [];

    const viGroups = Array.isArray(translation.option_groups) ? translation.option_groups : [];
    const enGroups = Array.isArray(translation.option_groups_en) && translation.option_groups_en.length
      ? translation.option_groups_en
      : viGroups;
    const targetGroups = lang === "en" ? enGroups : viGroups;

    return options.map(function (opt, groupIndex) {
      const viGroup = viGroups[groupIndex] || {};
      const enGroup = enGroups[groupIndex] || {};
      const targetGroup = targetGroups[groupIndex] || {};
      const viChoices = Array.isArray(viGroup.choices) ? viGroup.choices : [];
      const enChoices = Array.isArray(enGroup.choices) ? enGroup.choices : [];

      let choiceIndex = viChoices.indexOf(opt.choice);
      if (choiceIndex < 0) choiceIndex = enChoices.indexOf(opt.choice);

      const targetChoices = lang === "en" ? enChoices : viChoices;
      const choice = choiceIndex >= 0 && targetChoices[choiceIndex]
        ? targetChoices[choiceIndex]
        : opt.choice;

      return {
        group: targetGroup.name || opt.group,
        choice: choice
      };
    });
  }

  function applyProductLanguage() {
    api.getProducts().forEach(function (product) {
      const tr = productTranslations.get(Number(product.id));
      if (!tr) return;

      product.name = currentLang === "en" ? (tr.name_en || tr.name) : tr.name;
      product.description = currentLang === "en"
        ? (tr.description_en || tr.description || "")
        : (tr.description || "");

      const viOptions = Array.isArray(tr.option_groups) ? tr.option_groups : [];
      const enOptions = Array.isArray(tr.option_groups_en) && tr.option_groups_en.length
        ? tr.option_groups_en
        : viOptions;
      product.option_groups = currentLang === "en" ? enOptions : viOptions;
    });

    api.getCart().forEach(function (item) {
      const tr = productTranslations.get(Number(item.id));
      if (!tr) return;

      item.name = currentLang === "en" ? (tr.name_en || tr.name) : tr.name;

      if (Array.isArray(item.options) && item.options.length) {
        item.options = translateOptions(item.options, tr, currentLang);
        item.option_text = item.options.map(function (opt) { return opt.choice; }).join(" • ");
        item.variant_key = item.id + "::" + item.option_text;
      }
    });
  }

  function setLabel(id, value, html) {
    const label = document.querySelector('label[for="' + id + '"]');
    if (!label) return;
    if (html) label.innerHTML = value;
    else label.textContent = value;
  }

  function applyStaticLanguage() {
    const s = text[currentLang];
    document.documentElement.lang = currentLang === "en" ? "en" : "vi";

    const topbar = document.querySelector(".topbar");
    if (topbar) topbar.textContent = s.topbar;

    const subtitle = document.querySelector(".hero-subtitle");
    if (subtitle) subtitle.textContent = s.subtitle;

    const tagline = document.querySelector(".hero-tagline");
    if (tagline) tagline.textContent = s.tagline;

    const heroNote = document.querySelector(".hero-note");
    if (heroNote) heroNote.textContent = s.note;

    const cartBtn = document.getElementById("openCartBtn");
    if (cartBtn && cartBtn.firstChild) cartBtn.firstChild.nodeValue = s.cart;

    const drawerTitle = document.querySelector(".drawer-head strong");
    if (drawerTitle) drawerTitle.textContent = s.drawer;

    const totalLabel = document.querySelector(".total-row span:first-child");
    if (totalLabel) totalLabel.textContent = s.total;

    setLabel("customerName", s.customer);
    setLabel("deliveryMethod", s.fulfilment);
    setLabel("pickupDate", s.pickupDate);
    setLabel("pickupTime", s.pickupTime);
    setLabel("pickupPhone", s.phone + '<span class="optional-text">' + s.optional + "</span>", true);
    setLabel("recipientName", s.recipient);
    setLabel("recipientPhone", currentLang === "en" ? "Phone number" : "Số điện thoại");
    setLabel("shippingAddress", s.address);
    setLabel("customerNote", s.noteLabel);

    const fieldNote = document.querySelector(".field-note");
    if (fieldNote) fieldNote.textContent = s.phoneNote;

    const customerName = document.getElementById("customerName");
    if (customerName) customerName.placeholder = s.customerPh;

    const recipientName = document.getElementById("recipientName");
    if (recipientName) recipientName.placeholder = s.recipientPh;

    const shippingAddress = document.getElementById("shippingAddress");
    if (shippingAddress) shippingAddress.placeholder = s.addressPh;

    const note = document.getElementById("customerNote");
    if (note) note.placeholder = s.notePh;

    const deliveryMethod = document.getElementById("deliveryMethod");
    if (deliveryMethod) {
      const d = deliveryMethod.querySelector('option[value="delivery"]');
      if (d) d.textContent = currentLang === "en" ? "Melbourne Delivery" : "Delivery Melbourne";
    }

    const paymentLabel = document.querySelector(".pay-options");
    if (paymentLabel && paymentLabel.previousElementSibling) {
      paymentLabel.previousElementSibling.textContent = s.payment;
    }

    const makeOrderBtn = document.getElementById("makeOrderBtn");
    if (makeOrderBtn) makeOrderBtn.textContent = s.create;

    const copyOrderBtn = document.getElementById("copyOrderBtn");
    if (copyOrderBtn) copyOrderBtn.textContent = s.copy;

    const messengerBtn = document.getElementById("messengerBtn");
    if (messengerBtn) messengerBtn.textContent = s.messenger;

    const emailOrderBtn = document.getElementById("emailOrderBtn");
    if (emailOrderBtn && !emailOrderBtn.disabled) emailOrderBtn.textContent = s.email;

    const orderHelp = document.getElementById("orderHelp");
    if (orderHelp) orderHelp.innerHTML = s.help;

    document.querySelectorAll(".language-btn").forEach(function (btn) {
      btn.classList.toggle("active", btn.dataset.lang === currentLang);
    });

    document.querySelectorAll("#filters .filter").forEach(function (button) {
      if (button.dataset.category === "all") {
        button.textContent = currentLang === "en" ? "All" : "Tất cả";
        return;
      }
      const cat = categoryTranslations.get(button.dataset.category);
      if (cat) button.textContent = currentLang === "en" ? (cat.label_en || cat.label) : cat.label;
    });
  }

  function rerenderMenuAndCart() {
    api.renderFilters();
    api.renderProducts("all");
    api.updateCart();
    applyStaticLanguage();
  }

  function switchLanguage(lang) {
    currentLang = lang === "en" ? "en" : "vi";
    window.CCT_LANG = currentLang;
    localStorage.setItem("cct_lang", currentLang);
    applyProductLanguage();
    rerenderMenuAndCart();
  }

  window.CCT_setLanguage = switchLanguage;

  document.querySelectorAll(".language-btn").forEach(function (button) {
    button.addEventListener("click", function () {
      switchLanguage(button.dataset.lang);
    });
  });

  const makeOrderBtn = document.getElementById("makeOrderBtn");
  if (makeOrderBtn) {
    makeOrderBtn.addEventListener("click", async function (event) {
      if (currentLang !== "en") return;

      event.preventDefault();
      event.stopImmediatePropagation();

      const cart = api.getCart();
      if (!cart.length) {
        alert("Please add a product to your cart.");
        return;
      }

      const customerName = document.getElementById("customerName").value.trim();
      const deliveryMethod = document.getElementById("deliveryMethod");
      const pickupDate = document.getElementById("pickupDate");
      const pickupTime = document.getElementById("pickupTime");
      const pickupPhone = document.getElementById("pickupPhone");
      const recipientName = document.getElementById("recipientName");
      const recipientPhone = document.getElementById("recipientPhone");
      const shippingAddress = document.getElementById("shippingAddress");
      const note = document.getElementById("customerNote").value.trim() || "None";
      const payment = document.querySelector('input[name="payment"]:checked').value;

      if (!customerName) {
        alert("Please enter your name.");
        return;
      }

      if (deliveryMethod.value === "pickup") {
        if (!pickupDate.value || !pickupTime.value) {
          alert("Please choose a pickup date and time.");
          return;
        }
      } else if (!recipientName.value.trim() || !recipientPhone.value.trim() || !shippingAddress.value.trim()) {
        alert("Please enter the recipient name, phone number and delivery address.");
        return;
      }

      try {
        await api.commitStockForCurrentCart();
      } catch (error) {
        alert("One or more items are no longer available in the selected quantity. Please refresh and try again.");
        return;
      }

      const totalPrice = cart.reduce(function (sum, item) {
        return sum + item.price * item.qty;
      }, 0);

      const lines = cart.map(function (item) {
        return item.qty + " x " + item.name +
          (item.option_text ? " — " + item.option_text : "") +
          " $" + api.money(item.price * item.qty);
      }).join("\n");

      let orderText =
        customerName + "\n" +
        lines + "\n" +
        "Total: $" + api.money(totalPrice) + "\n";

      if (deliveryMethod.value === "pickup") {
        orderText +=
          "Fulfilment: Pick up Springvale" +
          "\nPickup date: " + pickupDate.value +
          "\nPickup time: " + pickupTime.value +
          (pickupPhone.value.trim() ? "\nPhone: " + pickupPhone.value.trim() : "");
      } else {
        const label = deliveryMethod.value === "auspost" ? "AusPost" : "Melbourne Delivery";
        orderText +=
          "Fulfilment: " + label + " (delivery fee quoted after order)" +
          "\nRecipient: " + recipientName.value.trim() +
          "\nPhone: " + recipientPhone.value.trim() +
          "\nAddress: " + shippingAddress.value.trim();
      }

      orderText += "\nPayment: " + payment + "\nNote: " + note;

      const orderBox = document.getElementById("orderBox");
      const orderHelp = document.getElementById("orderHelp");
      const copyOrderBtn = document.getElementById("copyOrderBtn");
      const messengerBtn = document.getElementById("messengerBtn");

      orderBox.textContent = orderText;
      orderBox.style.display = "block";
      orderHelp.style.display = "block";
      copyOrderBtn.style.display = "block";
      messengerBtn.style.display = "block";

      requestAnimationFrame(function () {
        orderBox.scrollIntoView({ behavior: "smooth", block: "start" });
      });

      try {
        await api.saveOrderDetails(orderText, customerName);
      } catch (error) {
        console.error(error);
      }

      try {
        await api.loadProducts();
        applyProductLanguage();
        api.renderFilters();
        api.renderProducts("all");
        api.updateCart();
        applyStaticLanguage();
      } catch (error) {
        console.error(error);
      }
    }, true);
  }

  loadTranslations()
    .then(function () {
      applyProductLanguage();
      rerenderMenuAndCart();
    })
    .catch(function (error) {
      console.error(error);
      applyStaticLanguage();
    });
});