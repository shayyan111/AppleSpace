import test from 'node:test';import assert from 'node:assert/strict';
import {reconcileCart,cartLines,cartTotal,escapeHtml} from '../store.js';
const p={id:'a',kind:'iphone',price:120000,quantity:1},a={id:'b',kind:'accessory',price:2000,quantity:3};
test('removes sold and hidden products and caps quantities to actual stock',()=>{assert.deepEqual(reconcileCart([{key:'iphone:a',quantity:4},{key:'accessory:b',quantity:5},{key:'iphone:sold',quantity:1}],[p,a]),[{key:'iphone:a',quantity:1},{key:'accessory:b',quantity:3}]);});
test('totals follow fresh catalogue prices instead of saved cart fields',()=>{const cart=[{key:'iphone:a',quantity:1,price:1},{key:'accessory:b',quantity:2,price:1}];assert.equal(cartTotal(cartLines(cart,[p,a])),124000);assert.equal(cartTotal(cartLines(cart,[{...p,price:125000},a])),129000);});
test('rejects unavailable or unpriced products',()=>{assert.deepEqual(reconcileCart([{key:'iphone:a',quantity:1}],[{...p,quantity:0}]),[]);assert.deepEqual(reconcileCart([{key:'iphone:a',quantity:1}],[{...p,price:0}]),[]);});
test('escapes listing content to prevent markup injection',()=>{assert.equal(escapeHtml('<img src=x onerror="alert(1)">'), '&lt;img src=x onerror=&quot;alert(1)&quot;&gt;');});
