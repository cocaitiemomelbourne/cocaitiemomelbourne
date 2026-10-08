(function(){
  function start(){
    var api=window.CCT_API;
    var grid=document.getElementById("featuredGrid");
    var promoGrid=document.getElementById("promoGrid");
    var search=document.getElementById("menuSearch");
    if(!api) return;

    var preferredIds=[10,5,2,1];
    var renderTimer=null;

    function inStock(p){
      return p && (p.stock_qty===null || p.stock_qty===undefined || Number(p.stock_qty)>0);
    }

    function desiredFeatured(){
      var products=(api.getProducts()||[]).slice();
      var selected=[];
      preferredIds.forEach(function(id){
        var p=products.find(function(x){return Number(x.id)===id;});
        if(inStock(p)) selected.push(p);
      });

      var fallbacks=products.filter(function(p){
        return inStock(p) &&
          !selected.some(function(x){return Number(x.id)===Number(p.id);}) &&
          !preferredIds.some(function(id){return id===Number(p.id);});
      }).sort(function(a,b){
        var af=(a.stock_qty===null||a.stock_qty===undefined)?-1:Number(a.stock_qty);
        var bf=(b.stock_qty===null||b.stock_qty===undefined)?-1:Number(b.stock_qty);
        if(bf!==af) return bf-af;
        return Number(a.id)-Number(b.id);
      });

      fallbacks.forEach(function(p){
        if(selected.length<4) selected.push(p);
      });
      return selected.slice(0,4);
    }

    function desiredSignature(){
      return desiredFeatured().map(function(p){return String(p.id);}).join(",");
    }

    function currentSignature(){
      if(!grid) return "";
      return Array.from(grid.querySelectorAll(".featured-card")).map(function(card){
        return String(card.getAttribute("data-v31-product-id")||"");
      }).join(",");
    }

    function renderFeaturedStable(){
      if(!grid) return;
      var featured=desiredFeatured();
      if(!featured.length) return;

      var wanted=featured.map(function(p){return String(p.id);}).join(",");
      if(currentSignature()===wanted && grid.querySelectorAll(".featured-card").length===4) return;

      grid.innerHTML="";
      featured.forEach(function(p){
        var card=document.createElement("div");
        card.className="featured-card";
        card.setAttribute("data-v31-product-id",String(p.id));

        var image=document.createElement("div");
        image.className="featured-img";
        if(p.image_url){
          var img=document.createElement("img");
          img.loading="lazy";
          img.decoding="async";
          img.fetchPriority="low";
          img.src=p.image_url;
          img.alt=p.name||"";
          image.appendChild(img);
        }else{
          image.textContent=p.emoji||"🍋";
        }

        var body=document.createElement("div");
        body.className="featured-body";
        var name=document.createElement("div");
        name.className="featured-name";
        name.textContent=(window.CCT_LANG==="en" && p.name_en)?p.name_en:(p.name||"");

        var bottom=document.createElement("div");
        bottom.className="featured-bottom";
        var price=document.createElement("strong");
        price.textContent="$"+api.money(p.price);
        var add=document.createElement("button");
        add.type="button";
        add.className="featured-add";
        add.textContent="+";
        add.dataset.productId=String(p.id);

        bottom.appendChild(price);
        bottom.appendChild(add);
        body.appendChild(name);
        body.appendChild(bottom);
        card.appendChild(image);
        card.appendChild(body);
        grid.appendChild(card);
      });
    }

    function scheduleFeatured(){
      clearTimeout(renderTimer);
      renderTimer=setTimeout(renderFeaturedStable,30);
    }

    function clearSearch(){
      if(!search) return;
      search.value="";
      search.dispatchEvent(new Event("input",{bubbles:true}));
    }

    function scrollToCategory(slug){
      clearSearch();
      var section=document.querySelector('[data-category-section="'+CSS.escape(String(slug))+'"]');
      var nav=document.getElementById("filters");
      if(nav){
        nav.querySelectorAll(".category-jump").forEach(function(b){b.classList.remove("active");});
        var btn=nav.querySelector('[data-category="'+CSS.escape(String(slug))+'"]');
        if(btn) btn.classList.add("active");
      }
      if(section){
        section.style.display="";
        section.scrollIntoView({behavior:"smooth",block:"start"});
        section.classList.remove("promo-highlight");
        void section.offsetWidth;
        section.classList.add("promo-highlight");
        setTimeout(function(){section.classList.remove("promo-highlight");},1600);
        return true;
      }
      return false;
    }

    function findProductCard(productId){
      var products=api.getProducts()||[];
      var index=products.findIndex(function(p){return String(p.id)===String(productId);});
      if(index<0) return null;
      return document.querySelector('#productGrid [data-add-index="'+index+'"]');
    }

    function scrollToProduct(productId){
      clearSearch();
      var add=findProductCard(productId);
      if(!add) return false;
      var card=add.closest(".product-card");
      if(!card) return false;
      var section=card.closest(".category-section");
      if(section) section.style.display="";
      card.scrollIntoView({behavior:"smooth",block:"center"});
      card.classList.remove("promo-highlight");
      void card.offsetWidth;
      card.classList.add("promo-highlight");
      setTimeout(function(){card.classList.remove("promo-highlight");},1600);
      return true;
    }

    if(grid){
      grid.addEventListener("click",function(e){
        var button=e.target.closest("[data-product-id]");
        if(!button) return;
        e.preventDefault();
        e.stopImmediatePropagation();
        var products=api.getProducts()||[];
        var p=products.find(function(x){return String(x.id)===String(button.dataset.productId);});
        if(!p) return;

        // Use an existing menu card's add button so option handling remains unchanged.
        var add=findProductCard(p.id);
        if(add) add.click();
      },true);

      new MutationObserver(function(){
        if(grid.querySelectorAll(".featured-card").length!==4 || currentSignature()!==desiredSignature()){
          scheduleFeatured();
        }
      }).observe(grid,{childList:true,subtree:false});
    }

    if(promoGrid){
      promoGrid.addEventListener("click",function(e){
        var btn=e.target.closest(".promo-btn");
        if(!btn) return;
        var card=btn.closest(".promo-banner");
        if(!card) return;

        // Match banner by visible title to current Supabase banner data is avoided here.
        // Instead infer target from button/card content for the two live banner types,
        // with robust fallback by section availability.
        var text=(card.textContent||"").toLowerCase();
        var isPreorder=text.indexOf("đặt trước")!==-1 || text.indexOf("pre-order")!==-1 || text.indexOf("preorder")!==-1;
        if(isPreorder){
          e.preventDefault();
          e.stopImmediatePropagation();
          scrollToCategory("dattruoc");
        }
      },true);
    }

    document.querySelectorAll("[data-lang]").forEach(function(btn){
      btn.addEventListener("click",function(){setTimeout(renderFeaturedStable,120);});
    });

    var attempts=0;
    var timer=setInterval(function(){
      attempts++;
      if((api.getProducts()||[]).length){
        clearInterval(timer);
        renderFeaturedStable();
      }else if(attempts>80){
        clearInterval(timer);
      }
    },100);

    // Reassert after legacy scripts' delayed renders.
    setTimeout(renderFeaturedStable,350);
    setTimeout(renderFeaturedStable,800);
  }

  if(document.readyState==="loading") document.addEventListener("DOMContentLoaded",start);
  else start();
})();