import {ImageMagick,initializeImageMagick,MagickFormat,MagickReadSettings,Gravity,CompositeOperator} from 'npm:@imagemagick/magick-wasm@0.0.44';
import {watermarkBase64} from './watermark.ts';
const wasm=await Deno.readFile(new URL(import.meta.resolve('npm:@imagemagick/magick-wasm@0.0.44/magick.wasm')));
await initializeImageMagick(wasm);
const watermark=Uint8Array.from(atob(watermarkBase64),c=>c.charCodeAt(0));
// Public preview service: validates API key and publication visibility; staff JWT
// is checked by PostgREST/website_can_manage before hidden media is permitted.
const base=Deno.env.get('SUPABASE_URL')!;
const service=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const publicKey='sb_publishable_tR1UVusyf4w2m9JdiHaLvg_zgpIFraR';
const cors={'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'apikey,authorization,content-type','Access-Control-Allow-Methods':'POST,OPTIONS','Cache-Control':'private, no-store','X-Content-Type-Options':'nosniff'};
Deno.serve(async req=>{
 if(req.method==='OPTIONS')return new Response(null,{headers:cors});
 if(req.method!=='POST'||req.headers.get('apikey')!==publicKey)return new Response('Not allowed',{status:403,headers:cors});
 try{
  const {ref}=await req.json();
  if(typeof ref!=='string'||ref.length>160)return new Response('Invalid photo',{status:400,headers:cors});
  const auth=req.headers.get('authorization');
  const check=await fetch(base+'/rest/v1/rpc/store_photo',{method:'POST',headers:{apikey:publicKey,'Content-Type':'application/json',...(auth?{Authorization:auth}:{})},body:JSON.stringify({ref})});
  if(!check.ok)return new Response('Photo unavailable',{status:404,headers:cors});
  const path=await check.json();
  if(typeof path!=='string'||!path||path.includes('..'))return new Response('Photo unavailable',{status:404,headers:cors});
  const hash=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(path)))).map(b=>b.toString(16).padStart(2,'0')).join('');
  const cachedPath='__watermarked/v1/'+hash+'.jpg';
  const storageHeaders={apikey:service,Authorization:'Bearer '+service};
  const cached=await fetch(base+'/storage/v1/object/authenticated/website-products/'+cachedPath,{headers:storageHeaders});
  if(cached.ok)return new Response(cached.body,{headers:{...cors,'Content-Type':'image/jpeg','Content-Disposition':'inline; filename="AppleSpace-product.jpg"'}});
  const photo=await fetch(base+'/storage/v1/object/authenticated/website-products/'+path.split('/').map(encodeURIComponent).join('/'),{headers:{apikey:service,Authorization:'Bearer '+service}});
  const type=photo.headers.get('content-type')?.split(';')[0]||'';
  if(!photo.ok||!['image/webp','image/png','image/jpeg'].includes(type))return new Response('Photo unavailable',{status:404,headers:cors});
  const input=new Uint8Array(await photo.arrayBuffer());
  if(input.length>25*1024*1024)return new Response('Image too large',{status:413,headers:cors});
  const settings=new MagickReadSettings();settings.setDefine('jpeg:size','1000x1000');
  const output=ImageMagick.read(input,settings,img=>{
   img.autoOrient();
   if(Math.max(img.width,img.height)>1000){const scale=1000/Math.max(img.width,img.height);img.resize(Math.round(img.width*scale),Math.round(img.height*scale))}
   ImageMagick.read(watermark,mark=>{const width=Math.max(80,Math.round(Math.min(img.width,img.height)*.55));mark.resize(width,Math.round(width*200/640));img.compositeGravity(mark,Gravity.Center,CompositeOperator.Over)});
   img.strip();img.quality=70;
   let result=img.write(MagickFormat.Jpeg,b=>Uint8Array.from(b));
   if(result.length>180*1024){img.quality=55;result=img.write(MagickFormat.Jpeg,b=>Uint8Array.from(b))}
   return result;
  });
  await fetch(base+'/storage/v1/object/website-products/'+cachedPath,{method:'POST',headers:{...storageHeaders,'Content-Type':'image/jpeg','x-upsert':'true'},body:output});
  return new Response(output,{headers:{...cors,'Content-Type':'image/jpeg','Content-Disposition':'inline; filename="AppleSpace-product.jpg"'}});
 }catch(e){console.error('Photo processing failed',e instanceof Error?e.message:'Unknown');return new Response('Photo unavailable',{status:400,headers:cors})}
});
