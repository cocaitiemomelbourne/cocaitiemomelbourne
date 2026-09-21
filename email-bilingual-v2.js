document.addEventListener("DOMContentLoaded", function () {
  const SUPABASE_URL = "https://eswrqkhsvlqndjbrgsqo.supabase.co";
  const SUPABASE_KEY = "sb_publishable_-6iIwPaZQRMkkWAROdfvxg_dmVB81E2";

  const orderBox = document.getElementById("orderBox");
  const successBox = document.getElementById("orderSuccess");
  const emailBtn = document.getElementById("emailOrderBtn");
  const deliveryMethod = document.getElementById("deliveryMethod");
  const pickupPhone = document.getElementById("pickupPhone");
  const recipientPhone = document.getElementById("recipientPhone");
  const customerName = document.getElementById("customerName");

  if (!orderBox || !successBox || !emailBtn) return;

  function isEnglish() {
    return window.CCT_LANG === "en";
  }

  function resetButton() {
    successBox.style.display = "none";
    successBox.textContent = "";
    emailBtn.style.display = "block";
    emailBtn.disabled = false;
    emailBtn.textContent = isEnglish()
      ? "✉️ Send order by Email"
      : "✉️ Gửi đơn hàng qua Email";
  }

  const observer = new MutationObserver(function () {
    if (!orderBox.textContent.trim() || orderBox.style.display === "none") return;
    resetButton();
  });

  observer.observe(orderBox, { childList:true, characterData:true, subtree:true });

  document.querySelectorAll(".language-btn").forEach(function (button) {
    button.addEventListener("click", function () {
      setTimeout(function () {
        if (!emailBtn.disabled) {
          emailBtn.textContent = isEnglish()
            ? "✉️ Send order by Email"
            : "✉️ Gửi đơn hàng qua Email";
        }
      }, 0);
    });
  });

  emailBtn.addEventListener("click", async function () {
    if (!orderBox.textContent.trim()) {
      alert(isEnglish() ? "Please create your order first." : "Vui lòng tạo đơn hàng trước.");
      return;
    }

    const phone = deliveryMethod.value === "pickup"
      ? pickupPhone.value.trim()
      : recipientPhone.value.trim();

    if (!phone) {
      alert(
        isEnglish()
          ? "Please enter a phone number so the shop can confirm your order."
          : "Vui lòng nhập số điện thoại để Tiệm liên hệ xác nhận đơn qua Email."
      );
      (deliveryMethod.value === "pickup" ? pickupPhone : recipientPhone).focus();
      return;
    }

    emailBtn.disabled = true;
    emailBtn.textContent = isEnglish() ? "Sending Email..." : "Đang gửi Email...";

    try {
      const response = await fetch(
        SUPABASE_URL + "/rest/v1/rpc/send_order_email_choice",
        {
          method:"POST",
          headers:{
            apikey:SUPABASE_KEY,
            Authorization:"Bearer " + SUPABASE_KEY,
            "Content-Type":"application/json"
          },
          body:JSON.stringify({
            p_customer_name:customerName.value.trim(),
            p_order_text:orderBox.textContent,
            p_phone:phone
          })
        }
      );

      if (!response.ok) throw new Error(await response.text());

      successBox.textContent = isEnglish()
        ? "Your order has been sent by Email and is awaiting confirmation. The shop will contact you using the phone number you provided."
        : "Đơn hàng của bạn đã được gửi qua Email và chờ xác nhận, tiệm sẽ liên hệ xác nhận sớm nhất thông qua số điện thoại bạn đã điền.";
      successBox.style.display = "block";
      emailBtn.textContent = isEnglish()
        ? "✓ Order sent by Email"
        : "✓ Đã gửi đơn qua Email";
    } catch (error) {
      console.error(error);
      emailBtn.disabled = false;
      emailBtn.textContent = isEnglish()
        ? "✉️ Send order by Email"
        : "✉️ Gửi đơn hàng qua Email";
      alert(
        isEnglish()
          ? "Email could not be sent. Please try again or use Messenger."
          : "Chưa gửi được Email. Vui lòng thử lại hoặc gửi đơn qua Messenger."
      );
    }
  });
});