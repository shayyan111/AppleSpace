export const money=value=>'Rs '+Number(value||0).toLocaleString('en-PK',{maximumFractionDigits:0});
export const ptaLabel=value=>({pta_approved:'PTA Approved',non_pta:'Non-PTA',jv:'JV'}[value]||'');
export const productKey=p=>p.kind+':'+p.id;
export function reconcileCart(cart,products){
 const map=new Map(products.map(p=>[productKey(p),p]));
 return cart.flatMap(line=>{const p=map.get(line.key);if(!p||p.quantity<1||p.price<=0)return [];return [{key:line.key,quantity:Math.min(Math.max(1,Math.floor(Number(line.quantity)||1)),p.quantity,20)}];});
}
export function cartLines(cart,products){const map=new Map(products.map(p=>[productKey(p),p]));return cart.flatMap(l=>{const p=map.get(l.key);return p?[{...p,quantity:l.quantity,maxQuantity:p.quantity}]:[];});}
export function cartTotal(lines){return lines.reduce((sum,p)=>sum+Number(p.price)*p.quantity,0);}
export function escapeHtml(value){return String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));}
