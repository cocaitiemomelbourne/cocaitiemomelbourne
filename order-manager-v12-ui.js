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

    /* Start on list screen on phone */
    if(isMobile()) document.body.classList.remove("v12-detail-open");
  });
})();