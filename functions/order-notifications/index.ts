// Credentials stay in Supabase Edge Function secrets, never in the storefront.
const base=Deno.env.get('SUPABASE_URL')!,service=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const names=['WHATSAPP_ACCESS_TOKEN','WHATSAPP_PHONE_NUMBER_ID','WHATSAPP_APP_SECRET','WHATSAPP_VERIFY_TOKEN','WHATSAPP_GRAPH_VERSION','ORDER_NOTIFICATION_CRON_SECRET'];
const config=Object.fromEntries(names.map(k=>[k,Deno.env.get(k)||'']));
const ready=()=>names.every(k=>!!config[k])&&/^v\d+\.\d+$/.test(config.WHATSAPP_GRAPH_VERSION)&&/^\d+$/.test(config.WHATSAPP_PHONE_NUMBER_ID)&&Deno.env.get('WHATSAPP_LIVE_ENABLED')==='true';
const json=(body:unknown,status=200)=>Response.json(body,{status,headers:{'Cache-Control':'no-store'}});
async function db(p:Record<string,unknown>){const r=await fetch(base+'/rest/v1/rpc/store_notification_worker',{method:'POST',headers:{apikey:service,Authorization:'Bearer '+service,'Content-Type':'application/json'},body:JSON.stringify({p}),signal:AbortSignal.timeout(15000)});if(!r.ok)throw Error('Notification database request failed');return r.json()}
function equal(a:string,b:string){if(a.length!==b.length)return false;let diff=0;for(let i=0;i<a.length;i++)diff|=a.charCodeAt(i)^b.charCodeAt(i);return diff===0}
async function signature(raw:string,header:string){if(!config.WHATSAPP_APP_SECRET||!/^sha256=[0-9a-f]{64}$/.test(header))return false;const k=await crypto.subtle.importKey('raw',new TextEncoder().encode(config.WHATSAPP_APP_SECRET),{name:'HMAC',hash:'SHA-256'},false,['sign']);const bytes=new Uint8Array(await crypto.subtle.sign('HMAC',k,new TextEncoder().encode(raw)));return equal(header,'sha256='+Array.from(bytes,b=>b.toString(16).padStart(2,'0')).join(''))}
Deno.serve(async req=>{
 const url=new URL(req.url),route=url.pathname.split('/').pop();
 if(route==='webhook'){
  if(req.method==='GET'){const token=config.WHATSAPP_VERIFY_TOKEN;if(token&&url.searchParams.get('hub.mode')==='subscribe'&&equal(url.searchParams.get('hub.verify_token')||'',token))return new Response(url.searchParams.get('hub.challenge')||'');return json({error:'Verification failed'},403)}
  if(req.method!=='POST')return json({error:'Method not allowed'},405);
  const raw=await req.text();if(raw.length>1024*1024)return json({error:'Payload too large'},413);
  if(!await signature(raw,req.headers.get('x-hub-signature-256')||''))return json({error:'Invalid signature'},401);
  try{const body=JSON.parse(raw);if(body.object!=='whatsapp_business_account')return json({ok:true});
   for(const entry of body.entry||[])for(const change of entry.changes||[]){const v=change.value;if(v?.metadata?.phone_number_id!==config.WHATSAPP_PHONE_NUMBER_ID)continue;
    for(const s of v.statuses||[])await db({action:'delivery',provider_id:s.id,correlation:s.biz_opaque_callback_data||'',phone:s.recipient_id,status:s.status,error_code:s.errors?.[0]?.code?String(s.errors[0].code):null});
    for(const m of v.messages||[])if(m.type==='text'&&/^(stop|unsubscribe)$/i.test(m.text?.body?.trim()||''))await db({action:'stop',phone:m.from});
   }return json({ok:true});
  }catch{return json({error:'Webhook could not be recorded; retry required'},503)}
 }
 if(route!=='process'||req.method!=='POST')return json({error:'Not found'},404);
 const secret=config.ORDER_NOTIFICATION_CRON_SECRET;
 if(!secret||!equal(req.headers.get('x-cron-secret')||'',secret))return json({error:'Unauthorized'},401);
 if(!ready())return json({enabled:false,reason:'WhatsApp setup incomplete or live sending disabled'});
 try{
  const jobs=await db({action:'claim'});let processed=0;
  for(const job of jobs){let outcome:Record<string,unknown>={action:'finish',id:job.id,lease_id:job.lease_id,status:'unknown',error_code:'ambiguous_provider_result_manual_review'};
   const values=['name','reference','items','amount','details'].map(k=>({type:'text',text:String(job.payload[k]).replace(/[\r\n\t]+/g,' ')}));
   try{
    const response=await fetch('https://graph.facebook.com/'+config.WHATSAPP_GRAPH_VERSION+'/'+config.WHATSAPP_PHONE_NUMBER_ID+'/messages',{method:'POST',headers:{Authorization:'Bearer '+config.WHATSAPP_ACCESS_TOKEN,'Content-Type':'application/json'},body:JSON.stringify({messaging_product:'whatsapp',to:job.phone,type:'template',template:{name:'aspace_order_'+job.event+'_v1',language:{code:'en'},components:[{type:'body',parameters:values}]},biz_opaque_callback_data:job.id}),signal:AbortSignal.timeout(20000)});
    const body=await response.json().catch(()=>({}));
    if(response.ok&&body.messages?.[0]?.id)outcome={...outcome,status:'accepted',provider_id:body.messages[0].id,error_code:null};
    else if(response.status===429)outcome={...outcome,status:'queued',error_code:'provider_rate_limited'};
    else if(response.status>=400&&response.status<500)outcome={...outcome,status:'failed',error_code:'meta_'+String(body.error?.code||response.status)};
    // Timeouts, 5xx and malformed success responses are ambiguous: never blindly resend.
   }catch{/* Keep unknown until a verified delivery webhook or manual investigation. */}
   await db(outcome);processed++;
  }
  return json({processed});
 }catch{return json({error:'Worker interrupted; inspect notification history'},503)}
});
