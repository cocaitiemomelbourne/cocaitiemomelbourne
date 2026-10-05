document.addEventListener("DOMContentLoaded", function () {
  var button = document.getElementById("lookupOrderBtn");
  var result = document.getElementById("lookupResult");
  var codeInput = document.getElementById("lookupOrderCode");
  var phoneInput = document.getElementById("lookupPhone");
  if (!button || !result || !codeInput || !phoneInput) return;

  function isEn(){ return window.CCT_LANG === "en"; }
  function esc(v){ return String(v == null ? "" : v).replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;"); }
  function money(v){ if(v===null||v===undefined||v==="") return ""; return "$"+Number(v||0).toFixed(2).replace(/\.00$/,""); }
  function displayDate(v){ return String(v||"").replace(/^(\d{4})-(\d{2})-(\d{2})$/,function(all,y,m,d){return d+"/"+m+"/"+y.slice(-2);}); }
  function statusText(v){
    var vi={new:"Mới",confirmed:"Đã xác nhận",preparing:"Đang chuẩn bị",ready:"Sẵn sàng",completed:"Hoàn tất",cancelled:"Đã huỷ"};
    var en={new:"New",confirmed:"Confirmed",preparing:"Preparing",ready:"Ready",completed:"Completed",cancelled:"Cancelled"};
    return (isEn()?en:vi)[v] || v || (isEn()?"New":"Mới");
  }
  function fulfilmentText(v){
    var value=String(v||"").toLowerCase();
    if(value==="pickup") return "Pick up Springvale";
    if(value==="delivery") return isEn()?"Melbourne delivery":"Delivery Melbourne";
    if(value==="auspost") return "AusPost";
    return v||"";
  }
  function legacyText(text,data){
    var shipping=data.fulfilment_method==="delivery"||data.fulfilment_method==="auspost";
    var pending=shipping&&data.delivery_fee==null;
    var amount=data.subtotal==null?data.total:Number(data.subtotal)+(shipping&&!pending?Number(data.delivery_fee):0);
    var lines=String(text||"").split(/\r?\n/);
    var summaryLines=lines.map(function(line,index){return /^(?:Tổng|Total|Tạm tính|Provisional total|Subtotal|Items subtotal|Tiền món):/.test(line)?index:-1;}).filter(function(index){return index>=0;});
    summaryLines.forEach(function(index,i){
      if(i===summaryLines.length-1)lines[index]=amount==null?lines[index].replace(/^[^:]+:/,pending?"Tạm tính:":"Tổng:"):(pending?"Tạm tính: ":"Tổng: ")+money(amount);
      else lines[index]=shipping?lines[index].replace(/^[^:]+:/,"Tiền món:"):"";
    });
    text=lines.join("\n").replace(/((?:Ngày pick up|Pickup date):\s*)(\d{4}-\d{2}-\d{2})/gi,function(all,label,date){return label+displayDate(date);});
    if(!isEn()) return text||"";
    var out=String(text||"");
    var pairs=[
      [/Tên khách:/g,"Customer:"],[/SĐT:/g,"Phone:"],[/Nhận hàng:/g,"Fulfilment:"],[/Ngày:/g,"Date:"],[/Giờ:/g,"Time:"],
      [/Tên người nhận:/g,"Recipient:"],[/Địa chỉ:/g,"Address:"],[/Thanh toán:/g,"Payment:"],[/Ghi chú:/g,"Note:"],
      [/Tổng:/g,"Total:"],[/Tạm tính:/g,"Provisional total:"],[/Tiền món:/g,"Items subtotal:"],[/báo giá sau khi tạo đơn/g,"quote after order"]
    ];
    pairs.forEach(function(p){out=out.replace(p[0],p[1]);});
    return out;
  }

  function row(label,value){
    if(value===null||value===undefined||String(value).trim()==="") return "";
    return '<div style="display:grid;grid-template-columns:minmax(105px,135px) 1fr;gap:10px;padding:7px 0;border-bottom:1px solid #eee4da"><strong>'+esc(label)+'</strong><span>'+esc(value)+'</span></div>';
  }

  function renderItems(items){
    if(!Array.isArray(items)||!items.length) return "";
    var title=isEn()?"Items":"Món đã đặt";
    var html='<div style="margin-top:14px"><strong>'+title+'</strong><div style="margin-top:6px;background:#fff;border-radius:12px;padding:4px 12px">';
    items.forEach(function(item){
      var name=item.name_en&&isEn()?item.name_en:(item.name||item.product_name||("#"+(item.id||"")));
      var qty=Number(item.qty||item.quantity||1);
      var option=item.option_text||item.variant||"";
      var price=item.line_total!=null?item.line_total:(item.price!=null?Number(item.price)*qty:null);
      html+='<div style="padding:10px 0;border-bottom:1px solid #f0e8df">'
        +'<div style="display:flex;justify-content:space-between;gap:12px"><span><strong>'+esc(qty+' × '+name)+'</strong>'+(option?'<div style="font-size:12px;color:#806f61;margin-top:3px">'+esc(option)+'</div>':'')+'</span>'
        +(price!=null?'<strong>'+money(price)+'</strong>':'')+'</div></div>';
    });
    html+='</div></div>';
    return html;
  }

  function render(data){
    if(!data.fulfilment_method){
      var match=String(data.order_text||"").match(/^(?:Nhận hàng|Fulfilment):\s*(.*)$/mi);
      if(match){var method=match[1].toLowerCase();data.fulfilment_method=method.indexOf("auspost")>=0?"auspost":method.indexOf("delivery")>=0?"delivery":method.indexOf("pick")>=0?"pickup":"";}
    }
    var locale=isEn()?"en-AU":"vi-VN";
    var created=data.created_at?new Date(data.created_at).toLocaleString(locale):"";
    var html='<div style="background:#eef8ef;border:1px solid #cfe5d2;border-radius:16px;padding:16px;color:#2f241b">'
      +'<div style="display:flex;justify-content:space-between;gap:12px;align-items:flex-start"><div><strong>'+esc(data.order_code||"")+'</strong>'
      +(created?'<div style="font-size:12px;color:#806f61;margin-top:3px">'+esc(created)+'</div>':'')
      +'</div><span style="background:#fff;padding:6px 10px;border-radius:999px;font-weight:900">'+esc(statusText(data.status))+'</span></div>';

    html+='<div style="margin-top:14px;background:#fff;border-radius:12px;padding:6px 12px">';
    html+=row(isEn()?"Customer":"Tên khách",data.customer_name);
    html+=row(isEn()?"Fulfilment":"Nhận hàng",fulfilmentText(data.fulfilment_method));
    if(String(data.fulfilment_method||"").toLowerCase()==="pickup"){
      html+=row(isEn()?"Pickup date":"Ngày pick up",displayDate(data.pickup_date));
      html+=row(isEn()?"Pickup time":"Giờ pick up",data.pickup_time);
    }
    html+=row(isEn()?"Recipient":"Người nhận",data.recipient_name);
    html+=row(isEn()?"Address":"Địa chỉ",data.shipping_address);
    html+=row(isEn()?"Payment":"Thanh toán",data.payment_method);
    html+=row(isEn()?"Note":"Ghi chú",data.customer_note);
    html+='</div>';

    html+=renderItems(data.order_items);

    if(data.subtotal!=null||data.delivery_fee!=null||data.total!=null){
      html+='<div style="margin-top:14px;background:#fff;border-radius:12px;padding:8px 12px">';
      var shipping=data.fulfilment_method==="delivery"||data.fulfilment_method==="auspost";
      var pending=shipping&&data.delivery_fee==null;
      var amount=data.subtotal==null?data.total:Number(data.subtotal)+(shipping&&!pending?Number(data.delivery_fee):0);
      if(shipping&&data.subtotal!=null) html+=row(isEn()?"Items subtotal":"Tiền món",money(data.subtotal));
      if(shipping) html+=row(isEn()?"Shipping fee":"Phí giao hàng",pending?(isEn()?"Quote pending":"Chờ báo giá"):money(data.delivery_fee));
      if(amount!=null) html+=row(pending?(isEn()?"Provisional total":"Tạm tính"):(isEn()?"Total":"Tổng"),money(amount));
      html+='</div>';
    }

    if((!Array.isArray(data.order_items)||!data.order_items.length)&&data.order_text){
      html+='<div style="margin-top:14px"><strong>'+(isEn()?"Order details":"Chi tiết đơn")+'</strong><pre style="white-space:pre-wrap;background:#fff;border-radius:12px;padding:12px;font-family:inherit;font-size:13px;line-height:1.55;margin-top:6px">'+esc(legacyText(data.order_text,data))+'</pre></div>';
    }

    html+='</div>';
    result.className="lookup-result ok";
    result.innerHTML=html;
  }

  button.addEventListener("click", async function(event){
    event.preventDefault();
    event.stopImmediatePropagation();
    var code=codeInput.value.trim().toUpperCase();
    var phone=phoneInput.value.trim();
    if(!code||!phone){
      result.className="lookup-result error";
      result.textContent=isEn()?"Please enter both order code and phone number.":"Vui lòng nhập đầy đủ mã đơn và số điện thoại.";
      return;
    }
    var source=Array.from(document.scripts).map(function(s){return s.textContent||"";}).join("\n");
    var keyMatch=source.match(/sb_publishable_[A-Za-z0-9_-]+/);
    if(!keyMatch){
      result.className="lookup-result error";
      result.textContent=isEn()?"Order information is unavailable right now.":"Không tải được thông tin đơn lúc này.";
      return;
    }
    button.disabled=true;
    button.textContent=isEn()?"Checking...":"Đang kiểm tra...";
    try{
      var response=await fetch("https://eswrqkhsvlqndjbrgsqo.supabase.co/rest/v1/rpc/lookup_order_details_v1",{
        method:"POST",
        headers:{apikey:keyMatch[0],Authorization:"Bearer "+keyMatch[0],"Content-Type":"application/json"},
        body:JSON.stringify({p_order_code:code,p_phone:phone})
      });
      var data=await response.json();
      if(!response.ok||!data||!data.found){
        result.className="lookup-result error";
        result.textContent=isEn()?"Order not found. Please check the order code and phone number.":"Không tìm thấy đơn. Vui lòng kiểm tra lại mã đơn và số điện thoại.";
      }else render(data);
    }catch(error){
      console.error(error);
      result.className="lookup-result error";
      result.textContent=isEn()?"Unable to check the order right now. Please try again.":"Chưa tra cứu được đơn lúc này. Vui lòng thử lại.";
    }
    button.disabled=false;
    button.textContent=isEn()?"Check status":"Kiểm tra";
  }, true);
});
