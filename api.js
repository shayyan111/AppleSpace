import {config} from './config.js';
const SESSION_KEY='applespace-website-session';
let session;
try {session=JSON.parse(sessionStorage.getItem(SESSION_KEY)||'null');}catch{session=null;}
let refreshPromise;
function keep(value){session=value; if(value)sessionStorage.setItem(SESSION_KEY,JSON.stringify(value));else sessionStorage.removeItem(SESSION_KEY);}
async function response(res){const data=await res.json().catch(()=>({}));if(!res.ok)throw new Error(data.msg||data.message||data.error_description||data.error||'Request failed. Please try again.');return data;}
async function token(){
 if(session && session.expires_at<Date.now()/1000+60){
  if(!refreshPromise) refreshPromise=fetch(config.supabaseUrl+'/auth/v1/token?grant_type=refresh_token',{method:'POST',headers:{apikey:config.publishableKey,'Content-Type':'application/json'},body:JSON.stringify({refresh_token:session.refresh_token})}).then(response).then(s=>{keep(s);return s.access_token;}).catch(e=>{keep(null);throw e;}).finally(()=>{refreshPromise=null;});
  return refreshPromise;
 }
 return session?.access_token;
}
export function signedIn(){return !!session;}
export async function login(email,password){const s=await response(await fetch(config.supabaseUrl+'/auth/v1/token?grant_type=password',{method:'POST',headers:{apikey:config.publishableKey,'Content-Type':'application/json'},body:JSON.stringify({email,password})}));keep(s);}
export async function logout(){try{const t=await token();if(t)await fetch(config.supabaseUrl+'/auth/v1/logout',{method:'POST',headers:{apikey:config.publishableKey,Authorization:'Bearer '+t}});}catch{}finally{keep(null);}}
export async function rpc(name,args={},authenticated=false){const t=authenticated?await token():null;if(authenticated&&!t)throw new Error('Please sign in again.');return response(await fetch(config.supabaseUrl+'/rest/v1/rpc/'+name,{method:'POST',headers:{apikey:config.publishableKey,'Content-Type':'application/json',...(t?{Authorization:'Bearer '+t}:{})},body:JSON.stringify(args),cache:'no-store'}));}
export function imageUrl(path){return config.supabaseUrl+'/storage/v1/object/public/website-products/'+path.split('/').map(encodeURIComponent).join('/');}
export async function uploadImage(file,product){
 if(!['image/jpeg','image/png','image/webp'].includes(file.type))throw new Error('Choose a JPG, PNG or WebP image.');
 if(file.size>5*1024*1024)throw new Error('Each photo must be smaller than 5 MB.');
 const t=await token();if(!t)throw new Error('Please sign in again.');
 const ext={'image/jpeg':'jpg','image/png':'png','image/webp':'webp'}[file.type];
 const path=session.user.id+'/'+product.id+'/'+crypto.randomUUID()+'.'+ext;
 await response(await fetch(config.supabaseUrl+'/storage/v1/object/website-products/'+path,{method:'POST',headers:{apikey:config.publishableKey,Authorization:'Bearer '+t,'Content-Type':file.type,'x-upsert':'false'},body:file}));
 try{await rpc('store_update',{p:{action:'media_add',id:product.id,kind:product.kind,path,alt:product.title,sort_order:(product.images?.length||0)+1}},true);}catch(e){await deleteImageObject(path).catch(()=>{});throw e;}
}
export async function deleteImageObject(path){const t=await token();await response(await fetch(config.supabaseUrl+'/storage/v1/object/website-products',{method:'DELETE',headers:{apikey:config.publishableKey,Authorization:'Bearer '+t,'Content-Type':'application/json'},body:JSON.stringify({prefixes:[path]})}));}
