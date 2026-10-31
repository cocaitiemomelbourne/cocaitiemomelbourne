const fs=require('fs'),vm=require('vm'),assert=require('assert');
const html=fs.readFileSync(require('path').join(__dirname,'../../sales-dashboard.html'),'utf8');
const source=html.match(/<script>([\s\S]*?)<\/script>/)[1];
let revision='1',loads=0,fail=false,mutate=false;
const elements={dashboard:{hidden:false},date:{value:'01/11/2026'},reload:{},loadStatus:{}};
const ctx={pass:'fixture',orders:[],document:{hidden:false,activeElement:null},navigator:{onLine:true},Date,
 $:id=>elements[id],isoFromDisplay:()=>true,
 rpc:async()=>({revision}),loadData:async()=>{loads++;if(fail)throw Error('offline');if(mutate){revision='4';mutate=false;}}};
vm.createContext(ctx);
ctx.autoRefresh=()=>ctx.load({background:true});
vm.runInContext(source.slice(source.indexOf('let loadInFlight='),source.indexOf('async function loadData()'))+
source.slice(source.indexOf('let revisionCheckInFlight='),source.indexOf('setInterval(checkCostRevision')),ctx);
(async()=>{
 await ctx.load();assert.equal(loads,1);
 await ctx.checkCostRevision();assert.equal(loads,1);
 revision='2';await ctx.checkCostRevision();assert.equal(loads,2);
 revision='3';fail=true;await ctx.checkCostRevision();assert.equal(loads,3);
 assert.match(elements.loadStatus.textContent,/giữ báo cáo/i);
 fail=false;await ctx.checkCostRevision();assert.equal(loads,4);
 revision='changed';mutate=true;await ctx.checkCostRevision();assert.equal(loads,5);
 await ctx.checkCostRevision();assert.equal(loads,6); // Change during loading is picked up next.
 ctx.document.hidden=true;revision='5';await ctx.checkCostRevision();assert.equal(loads,6);
 ctx.document.hidden=false;await Promise.all([ctx.checkCostRevision(),ctx.checkCostRevision()]);assert.equal(loads,7);
 console.log('PASS: unchanged, changed, failed retry, concurrent edit, hidden tab, coalescing');
})().catch(e=>{console.error(e);process.exitCode=1});
