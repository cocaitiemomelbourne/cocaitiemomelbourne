const fs=require('fs'),vm=require('vm'),assert=require('assert');
const html=fs.readFileSync(require('path').join(__dirname,'../../sales-dashboard.html'),'utf8');
const source=html.match(/<script>([\s\S]*?)<\/script>/)[1];
const elems=new Proxy({}, {get:(o,k)=>o[k]||(o[k]={value:k==='mode'?'month':'',classList:{toggle(){}},textContent:'',innerHTML:''})});
const ctx={$:id=>elems[id],range:()=>['2026-11-01','2026-12-01'],money:n=>'$'+Number(n).toFixed(2),safe:String,dateUTC:s=>new Date(s+'T12:00:00Z'),formatDateLong:String,formatDate:String,
 products:[{id:500,name:'Test retail',sku:'TEST'}],batches:[{id:10,product_id:500,received_on:'2026-10-01',quantity:10,unit_cost:2},{id:11,product_id:500,received_on:'2026-10-02',quantity:10,unit_cost:5}],
 orders:[{order_token:'before',order_number:'Before',status:'completed',pickup_date:'2026-11-01',created_at:'2026-11-01',order_items:[{id:500,name:'Test retail',qty:8,unit_price:10,line_total:80}]},{order_token:'after',order_number:'After',status:'completed',pickup_date:'2026-11-03',created_at:'2026-11-03',order_items:[{id:500,name:'Test retail',qty:2,unit_price:10,line_total:20}]}],
 singleCosts:[],comboCosts:[],specialCosts:[],shakeCosts:[],chickenCosts:[],confirmedCosts:[],monthlyRows:[],rows:[],gv004Costs:[],
 wasteEntries:[{id:'w',kind:'retail',name:'Test retail',sku:'TEST',occurred_on:'2026-11-02',lot_id:10,allocation_quantity:2,unit:'piece',reason:'damaged',cost:4},{id:'w',kind:'retail',name:'Test retail',sku:'TEST',occurred_on:'2026-11-02',lot_id:11,allocation_quantity:1,unit:'piece',reason:'damaged',cost:5}],
 sauceReport:{allocations:[],unresolved:[]},received:o=>o.pickup_date,items:o=>o.order_items,canonicalProduct:i=>({id:i.id,name:i.name}),historicalNames:new Map(),renderRows(){}};
vm.createContext(ctx);vm.runInContext(source.slice(source.indexOf('function render(){'),source.indexOf('function renderRows(){')),ctx);ctx.render();
assert.equal(elems.costMatched.textContent,'$26.00');assert.equal(elems.profit.textContent,'$74.00');assert.equal(elems.wasteTotal.textContent,'$9.00');assert.equal(elems.afterWaste.textContent,'$65.00');
assert.equal(ctx.monthlyRows[10].waste,9);assert.equal(ctx.rows[0].missing,0);
ctx.wasteEntries.forEach(w=>w.voided_at='2026-11-04');ctx.render();
assert.equal(elems.wasteTotal.textContent,'$0.00');assert.equal(elems.costMatched.textContent,'$20.00');assert.equal(elems.afterWaste.textContent,'$80.00');
ctx.orders[1].order_items[0].qty=50;ctx.render();assert.equal(elems.afterWaste.textContent,'Chưa đủ vốn');
console.log('PASS: no duplicate costs, past/future FIFO, month totals, voided waste and missing-cost profit protection');
