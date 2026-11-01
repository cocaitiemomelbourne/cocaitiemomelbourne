const allowedOrigins = new Set(['https://cocaitiemomelbourne.github.io', 'http://terminal.local:4173']);
const MAX = 350 * 1024;
const json = (body, status, headers) => new Response(JSON.stringify(body), {status, headers:{...headers,'Content-Type':'application/json','Cache-Control':'no-store'}});
Deno.serve(async req => {
 const origin=req.headers.get('Origin')||'';
 const cors={'Access-Control-Allow-Origin':allowedOrigins.has(origin)?origin:'https://cocaitiemomelbourne.github.io','Access-Control-Allow-Headers':'authorization, apikey, content-type','Access-Control-Allow-Methods':'POST, OPTIONS','Vary':'Origin'};
 if(origin&&!allowedOrigins.has(origin))return json({error:'origin_not_allowed'},403,cors);
 if(req.method==='OPTIONS')return new Response(null,{status:204,headers:cors});
 if(req.method!=='POST')return json({error:'method_not_allowed'},405,cors);
 if(Number(req.headers.get('Content-Length')||0)>MAX+20000)return json({error:'image_too_large'},413,cors);
 const url=Deno.env.get('SUPABASE_URL'),key=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
 const headers={apikey:key,Authorization:'Bearer '+key};
 try {
  const multipart=(req.headers.get('Content-Type')||'').includes('multipart/form-data');
  let form=null,data=null;
  if(multipart)form=await req.formData();else data=await req.json();
  const pass=multipart?form.get('passcode'):data?.passcode;
  if(typeof pass!=='string'||pass.length>200)return json({error:'not_authorized'},401,cors);
  const auth=await fetch(url+'/rest/v1/rpc/cct_menu_authorize_v1',{method:'POST',headers:{...headers,'Content-Type':'application/json'},body:JSON.stringify({p_passcode:pass})});
  if(!auth.ok||await auth.json()!==true)return json({error:'not_authorized'},401,cors);
  if(!multipart){
   if(data?.action!=='cleanup'||typeof data?.image_url!=='string')return json({error:'invalid_request'},400,cors);
   const prefix=url+'/storage/v1/object/public/product-images/';
   const path=data.image_url.startsWith(prefix)?data.image_url.slice(prefix.length):'';
   if(!/^menu\/[0-9a-f-]{36}\.(webp|jpg|png)$/.test(path))return json({ok:true,skipped:true},200,cors);
   for(const table of ['products','products_draft']){
    const r=await fetch(url+'/rest/v1/'+table+'?select=id&image_url=eq.'+encodeURIComponent(data.image_url)+'&limit=1',{headers});
    if(!r.ok)return json({error:'reference_check_failed'},503,cors);
    if((await r.json()).length)return json({ok:true,referenced:true},200,cors);
   }
   const r=await fetch(url+'/storage/v1/object/product-images',{method:'DELETE',headers:{...headers,'Content-Type':'application/json'},body:JSON.stringify({prefixes:[path]})});
   if(!r.ok)return json({error:'cleanup_failed'},503,cors);
   return json({ok:true},200,cors);
  }
  const file=form.get('image');
  if(!(file instanceof File)||file.size<12||file.size>MAX)return json({error:'image_too_large'},400,cors);
  const b=new Uint8Array(await file.arrayBuffer());
  const ascii=(start,end)=>String.fromCharCode(...b.slice(start,end));
  const webp=ascii(0,4)==='RIFF'&&ascii(8,12)==='WEBP';
  const jpg=b[0]===255&&b[1]===216&&b[2]===255;
  const png=b[0]===137&&ascii(1,4)==='PNG'&&b[4]===13&&b[5]===10&&b[6]===26&&b[7]===10;
  const type=webp?'image/webp':jpg?'image/jpeg':png?'image/png':null;
  if(!type||file.type!==type)return json({error:'invalid_image'},400,cors);
  const path='menu/'+crypto.randomUUID()+'.'+(webp?'webp':jpg?'jpg':'png');
  const result=await fetch(url+'/storage/v1/object/product-images/'+path,{method:'POST',headers:{...headers,'Content-Type':type,'Cache-Control':'max-age=31536000','x-upsert':'false'},body:b});
  if(!result.ok)return json({error:'upload_failed'},503,cors);
  return json({ok:true,image_url:url+'/storage/v1/object/public/product-images/'+path,size:file.size},200,cors);
 }catch{return json({error:'request_failed'},400,cors);}
});
