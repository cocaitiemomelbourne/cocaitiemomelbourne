document.addEventListener("DOMContentLoaded", function () {
  var SUPABASE_URL = "https://eswrqkhsvlqndjbrgsqo.supabase.co";
  var SUPABASE_KEY = "sb_publishable_-6iIwPaZQRMkkWAROdfvxg_dmVB81E2";
  var bannerData = [];

  function isEn(){ return window.CCT_LANG === "en"; }

  function applySectionHeadings(){
    var sections = document.querySelectorAll(".checkout-section-title");
    if (sections[0]) sections[0].textContent = isEn() ? "CONTACT INFORMATION" : "THÔNG TIN LIÊN HỆ";
    if (sections[1]) sections[1].textContent = isEn() ? "FULFILMENT" : "NHẬN HÀNG";
  }

  function applyMeta(){
    document.documentElement.lang = isEn() ? "en" : "vi";
    document.title = isEn() ? "Có Cái Tiệm | Melbourne Vietnamese Snacks" : "Có Cái Tiệm | Ăn Vặt Melbourne";
  }

  function applyBannerText(){
    if (!bannerData.length) return;
    var cards = document.querySelectorAll("#promoGrid .promo-banner");
    cards.forEach(function(card, index){
      var b = bannerData[index];
      if (!b) return;
      var title = card.querySelector(".promo-title");
      var subtitle = card.querySelector(".promo-subtitle");
      var button = card.querySelector(".promo-btn");
      if (title) title.textContent = isEn() ? (b.title_en || b.title || "") : (b.title || "");
      if (subtitle) subtitle.textContent = isEn() ? (b.subtitle_en || b.subtitle || "") : (b.subtitle || "");
      if (button) button.textContent = isEn() ? (b.button_text_en || b.button_text || "View") : (b.button_text || "Xem ngay");
    });
  }

  function applyMisc(){
    applyMeta();
    applySectionHeadings();
    applyBannerText();

    var contactLabel = document.querySelector('label[for="contactEmail"]');
    if (contactLabel) {
      contactLabel.innerHTML = isEn()
        ? 'Contact email <span class="optional-text">(optional)</span>'
        : 'Email liên hệ <span class="optional-text">(không bắt buộc)</span>';
    }

    var menuHeading = document.querySelector("main.main > h2");
    if (menuHeading) menuHeading.textContent = "Menu";
  }

  async function loadBannerTranslations(){
    try{
      var response = await fetch(
        SUPABASE_URL + "/rest/v1/site_banners?select=banner_key,title,title_en,subtitle,subtitle_en,button_text,button_text_en,sort_order&order=sort_order.asc,banner_key.asc",
        {headers:{apikey:SUPABASE_KEY,Authorization:"Bearer "+SUPABASE_KEY}}
      );
      if (!response.ok) return;
      var data = await response.json();
      if (Array.isArray(data)) bannerData = data;
      applyBannerText();
    }catch(error){ console.error(error); }
  }

  document.querySelectorAll("[data-lang]").forEach(function(button){
    button.addEventListener("click", function(){ setTimeout(applyMisc, 120); });
  });

  var promoGrid = document.getElementById("promoGrid");
  if (promoGrid) {
    new MutationObserver(function(){ setTimeout(applyBannerText, 30); }).observe(promoGrid,{childList:true,subtree:true});
  }

  setTimeout(applyMisc, 160);
  setTimeout(loadBannerTranslations, 260);
});
