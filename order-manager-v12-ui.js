(function(){
  function ready(fn){
    if(document.readyState==="loading") document.addEventListener("DOMContentLoaded",fn);
    else fn();
  }

  ready(function(){
    var detail=document.querySelector(".v9-detail-pane");
    var detailTitle=document.querySelector(".v9-detail-title");
    var orders=document.getElementById("orders");
    var editRows=document.getElementById("editRows");
    var pricing=document.querySelector(".pricing");
    var discountEditor=document.querySelector(".discount-editor");
    var panelDiscount=document.getElementById("panelDiscount");
    if(!detail||!detailTitle||!orders||!editRows) return;

    function isMobile(){return window.matchMedia("(max-width:760px)").matches}

    /* Full-screen detail navigation */
    var back=document.createElement("button");
    back.type="button";
    back.className="v12-back";
    back.textContent="← Danh sách";

    var name=document.createElement("div");
    name.className="v12-detail-name";
    name.textContent="Chi tiết đơn";

    detailTitle.innerHTML="";
    detailTitle.appendChild(back);
    detailTitle.appendChild(name);

    back.addEventListener("click",function(){
      document.body.classList.remove("v12-detail-open");
    });

    orders.addEventListener("click",function(event){
      var row=event.target.closest("[data-token]");
      if(!row||!isMobile()) return;
      setTimeout(function(){
        var number=document.getElementById("orderNumber");
        name.textContent=number&&number.textContent&&number.textContent!=="—" ? number.textContent : "Chi tiết đơn";
        detail.scrollTop=0;
        document.body.classList.add("v12-detail-open");
      },30);
    });

    window.addEventListener("resize",function(){
      if(!isMobile()) document.body.classList.remove("v12-detail-open");
    });

    /* Compact item rows */
    function rowSummary(row){
      var select=row.querySelector(".product-select");
      var customName=row.querySelector(".custom-name");
      var qty=row.querySelector(".qty-input");
      var price=row.querySelector(".override-price,.custom-price");

      var itemName="Món";
      if(customName) itemName=customName.value.trim()||"Món ngoài menu";
      else if(select){
        var opt=select.options[select.selectedIndex];
        itemName=opt ? String(opt.textContent||"").split(" — ")[0].trim() : "Chọn món";
      }

      var q=qty&&qty.value ? qty.value : "1";
      var p=price&&price.value!=="" ? Number(price.value) : null;

      return {
        name:itemName,
        qty:"SL "+q,
        price:p===null||!Number.isFinite(p) ? "$—" : "$"+p.toFixed(2).replace(/\.00$/,"")
      };
    }

    function decorateRow(row){
      if(row.querySelector(":scope > .v12-item-summary")) return;
      var summary=document.createElement("div");
      summary.className="v12-item-summary";

      var n=document.createElement("div"); n.className="v12-item-name";
      var q=document.createElement("div"); q.className="v12-item-qty";
      var p=document.createElement("div"); p.className="v12-item-price";
      var more=document.createElement("button");
      more.type="button"; more.className="v12-item-more"; more.textContent="⋯";

      summary.appendChild(n);summary.appendChild(q);summary.appendChild(p);summary.appendChild(more);
      row.insertBefore(summary,row.firstChild);

      function refresh(){
        var x=rowSummary(row);
        n.textContent=x.name;q.textContent=x.qty;p.textContent=x.price;
      }
      refresh();

      more.addEventListener("click",function(){
        row.classList.toggle("v12-expanded");
        more.textContent=row.classList.contains("v12-expanded")?"×":"⋯";
        refresh();
      });
      row.addEventListener("input",refresh);
      row.addEventListener("change",function(){setTimeout(refresh,0)});
    }

    function decorateRows(){
      editRows.querySelectorAll(".edit-row").forEach(decorateRow);
    }
    new MutationObserver(decorateRows).observe(editRows,{childList:true});
    decorateRows();

    /* Compact discount */
    if(pricing&&discountEditor){
      var trigger=document.createElement("button");
      trigger.type="button";
      trigger.className="v12-discount-trigger";
      function refreshDiscount(){
        var txt=panelDiscount ? panelDiscount.textContent : "$0";
        trigger.innerHTML="<span>Discount</span><span>"+txt+" ›</span>";
      }
      refreshDiscount();
      pricing.insertBefore(trigger,discountEditor);
      trigger.addEventListener("click",function(){
        pricing.classList.toggle("v12-discount-open");
      });
      if(panelDiscount){
        new MutationObserver(refreshDiscount).observe(panelDiscount,{childList:true,characterData:true,subtree:true});
      }
    }


    /* Compact mobile order view: actions first, optional editors and receipt. */
    var preview=document.querySelector(".v9-detail-pane .selected-order-preview");
    var dateEditor=document.getElementById("receiptDateEditor");
    var receiptCard=preview&&preview.querySelector(".preview-card");
    if(preview&&dateEditor&&receiptCard){
      var summary=document.createElement("div");
      summary.className="v13-overview card";
      summary.innerHTML='<div class="v13-overview-head"><span>THÔNG TIN ĐƠN</span><strong data-v13="number">—</strong></div><div class="v13-overview-customer" data-v13="customer">Chọn một đơn hàng</div><div class="v13-overview-grid"><div><small>Nhận hàng</small><b data-v13="pickup">—</b></div><div><small>Tổng thanh toán</small><b data-v13="total">—</b></div></div>';
      preview.insertBefore(summary,dateEditor);
      function makeToggle(target,title,caption){
        var toggle=document.createElement("button");
        toggle.type="button";toggle.className="v13-fold-toggle";
        toggle.setAttribute("aria-expanded","false");
        toggle.innerHTML='<span>'+title+'<small>'+caption+'</small></span><span class="v13-chevron">⌄</span>';
        target.parentNode.insertBefore(toggle,target);
        target.classList.add("v13-fold-content");
        toggle.addEventListener("click",function(){
          var open=target.classList.toggle("v13-expanded");
          toggle.setAttribute("aria-expanded",String(open));
        });
        return toggle;
      }
      makeToggle(dateEditor,"📅 Chỉnh ngày / giờ nhận","Chỉ mở khi cần thay đổi");
      // Receipt is always visible; print and copy actions share the same section.
      receiptCard.classList.add("v13-receipt-visible");
      var printTools=document.querySelector(".v9-detail-pane .top-print");
      if(printTools){
        printTools.classList.add("v14-print-tools");
        printTools.querySelector("h3").textContent="In & sao chép đơn";
        preview.insertBefore(printTools,receiptCard);
      }
      // Keep order item editing immediately after the visible order receipt.
      var editPanel=document.querySelector(".v9-detail-pane .edit-items");
      if(editPanel){
        editPanel.classList.add("v14-edit-panel");
        preview.insertAdjacentElement("afterend",editPanel);
      }
      var nodeIds={number:"orderNumber",customer:"customerName",pickup:"pickup",total:"total"};
      function syncOverview(){
        Object.keys(nodeIds).forEach(function(key){
          var src=document.getElementById(nodeIds[key]);
          var dest=summary.querySelector('[data-v13="'+key+'"]');
          if(dest&&src)dest.textContent=src.textContent.trim()||"—";
        });
      }
      Object.keys(nodeIds).forEach(function(key){
        var src=document.getElementById(nodeIds[key]);
        if(src)new MutationObserver(syncOverview).observe(src,{childList:true,characterData:true,subtree:true});
      });
      syncOverview();
    }

    /* Start on list screen on phone */
    if(isMobile()) document.body.classList.remove("v12-detail-open");
  });
})();