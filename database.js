export const databaseUrl='https://ghmofddxpflpopwavysk.supabase.co';
const key='sb_publishable_tR1UVusyf4w2m9JdiHaLvg_zgpIFraR';
export function session(){try{return JSON.parse(sessionStorage.getItem('aspace-session')||'null')}catch{return null}}
export async function signIn(email,password){const r=await fetch(databaseUrl+'/auth/v1/token?grant_type=password',{method:'POST',signal:AbortSignal.timeout(20000),headers:{apikey:key,'Content-Type':'application/json'},body:JSON.stringify({email,password})});const b=await r.json();if(!r.ok)throw Error(b.msg||b.error_description||'Sign in failed');sessionStorage.setItem('aspace-session',JSON.stringify(b));return b}
export async function signOut(){const s=session();sessionStorage.removeItem('aspace-session');if(s)await fetch(databaseUrl+'/auth/v1/logout',{method:'POST',signal:AbortSignal.timeout(20000),headers:{apikey:key,Authorization:'Bearer '+s.access_token}})}
async function token(){let s=session();if(s&&s.expires_at*1000<Date.now()+60000){const r=await fetch(databaseUrl+'/auth/v1/token?grant_type=refresh_token',{method:'POST',signal:AbortSignal.timeout(20000),headers:{apikey:key,'Content-Type':'application/json'},body:JSON.stringify({refresh_token:s.refresh_token})});if(!r.ok){sessionStorage.removeItem('aspace-session');throw Error('Your session expired. Sign in again.')}s=await r.json();sessionStorage.setItem('aspace-session',JSON.stringify(s))}return s?.access_token}
export async function rpc(name,body={},authenticated=false){const t=authenticated?await token():undefined;if(authenticated&&!t)throw Error('Sign in to manage the website.');const r=await fetch(databaseUrl+'/rest/v1/rpc/'+name,{method:'POST',signal:AbortSignal.timeout(20000),headers:{apikey:key,'Content-Type':'application/json',...(t?{Authorization:'Bearer '+t}:{})},body:JSON.stringify(body)});const b=await r.json();if(!r.ok)throw Error(b.message||'We couldn’t connect. Please try again.');return b}
export async function compressPhoto(file){
 if(!['image/jpeg','image/png','image/webp'].includes(file.type)||file.size>25*1024*1024)throw Error('Choose JPG, PNG or WebP, up to 25 MB.');
 let source,url;
 try{
  if(typeof createImageBitmap==='function')source=await createImageBitmap(file);
  else{url=URL.createObjectURL(file);source=await new Promise((resolve,reject)=>{const img=new Image();img.onload=()=>resolve(img);img.onerror=()=>reject(Error('This photo could not be read.'));img.src=url})}
  const width=source.width,height=source.height;if(!width||!height)throw Error('Invalid image dimensions.');
  const canvas=document.createElement('canvas'),ctx=canvas.getContext('2d');if(!ctx)throw Error('Image compression is unavailable in this browser.');
  let best=null;
  for(const limit of [1600,1280,1024]){
   const scale=Math.min(1,limit/Math.max(width,height));canvas.width=Math.max(1,Math.round(width*scale));canvas.height=Math.max(1,Math.round(height*scale));ctx.drawImage(source,0,0,canvas.width,canvas.height);
   for(const quality of [.8,.68,.56]){
    let blob=await new Promise(resolve=>canvas.toBlob(resolve,'image/webp',quality));
    if(!blob||blob.type!=='image/webp'){ctx.save();ctx.globalCompositeOperation='destination-over';ctx.fillStyle='#dfe1e5';ctx.fillRect(0,0,canvas.width,canvas.height);ctx.restore();blob=await new Promise(resolve=>canvas.toBlob(resolve,'image/jpeg',quality))}
    if(!blob)throw Error('Image compression failed. Please try another photo.');
    if(!best||blob.size<best.size)best=blob;if(best.size<=180*1024)break;
   }
   if(best.size<=180*1024)break;
  }
  if(file.size<best.size&&Math.max(width,height)<=1600)return file;
  if(best.size>5*1024*1024)throw Error('This photo could not be compressed enough. Please choose a smaller image.');
  return best;
 }catch(e){throw Error(e.message||'This photo could not be compressed. Try a JPG, PNG or WebP image.')}
 finally{source?.close?.();if(url)URL.revokeObjectURL(url)}
}
export async function uploadPhoto(file){const s=session(),t=await token();if(!s||!t)throw Error('Sign in first.');const compressed=await compressPhoto(file);const path=s.user.id+'/'+crypto.randomUUID()+'.'+({'image/jpeg':'jpg','image/png':'png','image/webp':'webp'}[compressed.type]);const r=await fetch(databaseUrl+'/storage/v1/object/website-products/'+path,{method:'POST',signal:AbortSignal.timeout(20000),headers:{apikey:key,Authorization:'Bearer '+t,'Content-Type':compressed.type},body:compressed});if(!r.ok)throw Error('Photo upload failed. Check your website access.');return path}
// Opaque references become document-local blob URLs; originals are never linked.
export const photoAttributes=ref=>'src="/images/photo-placeholder.svg" data-product-photo="'+encodeURIComponent(ref)+'"';
const photoCache=new Map();
async function loadPhoto(img){
 const ref=decodeURIComponent(img.dataset.productPhoto);if(img.dataset.photoLoading)return;img.dataset.photoLoading='1';
 try{
  if(!photoCache.has(ref))photoCache.set(ref,(async()=>{
   const t=document.body.dataset.page==='manager'?await token():null;
   const r=await fetch(databaseUrl+'/functions/v1/product-photo',{method:'POST',signal:AbortSignal.timeout(20000),headers:{apikey:key,'Content-Type':'application/json',...(t?{Authorization:'Bearer '+t}:{})},body:JSON.stringify({ref})});
   if(!r.ok)throw Error('Photo unavailable');return URL.createObjectURL(await r.blob());
  })().catch(e=>{photoCache.delete(ref);throw e}));
  img.src=await photoCache.get(ref);
 }catch{img.alt=(img.alt||'Product')+' — photo temporarily unavailable';delete img.dataset.photoLoading;}
}
const photoObserver=new IntersectionObserver(entries=>{for(const e of entries)if(e.isIntersecting){photoObserver.unobserve(e.target);loadPhoto(e.target)}},{rootMargin:'300px'});
function scanPhotos(){document.querySelectorAll('img[data-product-photo]:not([data-photo-observed])').forEach(img=>{img.dataset.photoObserved='1';photoObserver.observe(img)})}
new MutationObserver(scanPhotos).observe(document.documentElement,{childList:true,subtree:true});
scanPhotos();
window.addEventListener('pagehide',event=>{if(event.persisted)return;for(const p of photoCache.values())p.then(URL.revokeObjectURL).catch(()=>{});photoCache.clear()});
