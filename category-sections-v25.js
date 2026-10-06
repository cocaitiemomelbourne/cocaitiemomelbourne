(function(){
  function start(){
    var api=window.CCT_API;
    var productGrid=document.getElementById("productGrid");
    var filters=document.getElementById("filters");
    var search=document.getElementById("menuSearch");
    var searchEmpty=document.getElementById("searchEmpty");
    if(!api||!productGrid||!filters) return;

    var rebuilding=false;
    var scheduled=null;

    function esc(v){
      return String(v==null?"":v).replace(/[&<>"']/g,function(c){
        return {"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c];
      });
    }

    function currentLabels(){
      var map={};
      filters.querySelectorAll("[data-category]").forEach(function(btn){
        var slug=btn.getAttribute("data-category");
        if(slug && slug!=="all") map[slug]=(btn.textContent||"").trim();
      });
      return map;
    }

    function categoryList(){
      var categories=(api.getCategories()||[]).slice();
      var products=api.getProducts()||[];
      var seen={};
      categories.forEach(function(c){ if(c&&c.slug) seen[c.slug]=true; });
      products.forEach(function(p){
        var cats=Array.isArray(p.categories)?p.categories:(p.category?[p.category]:[]);
        cats.forEach(function(slug){
          if(!slug||seen[slug]) return;
          seen[slug]=true;
          categories.push({slug:slug,label:slug,sort_order:999});
        });
      });
      return categories.sort(function(a,b){
        var sa=Number(a.sort_order||0), sb=Number(b.sort_order||0);
        if(sa!==sb) return sa-sb;
        return String(a.label||a.slug||"").localeCompare(String(b.label||b.slug||""),window.CCT_LANG==="en"?"en":"vi");
      });
    }

    function build(){
      if(rebuilding) return;
      var products=api.getProducts()||[];
      if(!products.length) return;
      rebuilding=true;

      try{
        var labels=currentLabels();
        var categories=categoryList();
        var sections=[];

        categories.forEach(function(cat){
          if(!cat||!cat.slug||cat.slug==="all") return;
          api.renderProducts(cat.slug);
          var cards=Array.from(productGrid.children).filter(function(el){
            return el.classList&&el.classList.contains("product-card");
          });
          if(!cards.length) return;

          var label=labels[cat.slug] || cat.label || cat.slug;
          var cardHtml=cards.map(function(card){return card.outerHTML;}).join("");
          sections.push({
            slug:cat.slug,
            label:label,
            html:'<section class="category-section" id="menu-'+esc(cat.slug)+'" data-category-section="'+esc(cat.slug)+'">'+
              '<div class="category-section-head"><h3>'+esc(label)+'</h3><span>'+cards.length+' '+(window.CCT_LANG==="en"?"items":"món")+'</span></div>'+
              '<div class="category-products">'+cardHtml+'</div>'+
            '</section>'
          });
        });

        var nav=['<button type="button" class="filter active category-hidden-all" data-category="all" aria-hidden="true" tabindex="-1">All</button>'];
        sections.forEach(function(sec){
          nav.push('<button type="button" class="filter category-jump" data-category="'+esc(sec.slug)+'">'+esc(sec.label)+'</button>');
        });
        filters.innerHTML=nav.join("");
        filters.classList.add("category-jump-nav");

        productGrid.classList.add("category-sections-container");
        productGrid.innerHTML=sections.map(function(sec){return sec.html;}).join("");

        filters.querySelectorAll(".category-jump").forEach(function(btn){
          btn.addEventListener("click",function(){
            filters.querySelectorAll(".category-jump").forEach(function(x){x.classList.remove("active");});
            btn.classList.add("active");
            var section=document.getElementById("menu-"+btn.dataset.category);
            if(section) section.scrollIntoView({behavior:"smooth",block:"start"});
          });
        });

        updateSectionVisibility();
      } finally {
        rebuilding=false;
      }
    }

    function updateSectionVisibility(){
      var query=search ? String(search.value||"").trim() : "";
      productGrid.querySelectorAll(".category-section").forEach(function(section){
        var cards=Array.from(section.querySelectorAll(".product-card"));
        var visible=cards.some(function(card){return card.style.display!=="none";});
        section.style.display=visible ? "" : "none";
      });
      if(!query){
        productGrid.querySelectorAll(".category-section").forEach(function(section){section.style.display="";});
      }
      if(searchEmpty && query){
        var any=Array.from(productGrid.querySelectorAll(".product-card")).some(function(card){return card.style.display!=="none";});
        searchEmpty.style.display=any?"none":"block";
      }
    }

    function scheduleBuild(delay){
      clearTimeout(scheduled);
      scheduled=setTimeout(function(){
        var hasSections=productGrid.querySelector(":scope > .category-section");
        if(!hasSections) build();
      },delay||120);
    }

    if(search){
      search.addEventListener("input",function(){requestAnimationFrame(updateSectionVisibility);});
      search.addEventListener("search",function(){requestAnimationFrame(updateSectionVisibility);});
    }

    document.querySelectorAll("[data-lang]").forEach(function(btn){
      btn.addEventListener("click",function(){
        setTimeout(function(){build();},260);
      });
    });

    new MutationObserver(function(){
      if(rebuilding) return;
      var hasSections=productGrid.querySelector(":scope > .category-section");
      if(!hasSections) scheduleBuild(80);
    }).observe(productGrid,{childList:true,subtree:false});

    var tries=0;
    var timer=setInterval(function(){
      tries++;
      if((api.getProducts()||[]).length){
        clearInterval(timer);
        setTimeout(build,220);
      }else if(tries>80){
        clearInterval(timer);
      }
    },100);
  }

  if(document.readyState==="loading") document.addEventListener("DOMContentLoaded",start);
  else start();
})();