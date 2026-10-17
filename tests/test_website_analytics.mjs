import test from 'node:test';
import assert from 'node:assert/strict';
import vm from 'node:vm';
import fs from 'node:fs';
import {randomUUID} from 'node:crypto';
const source=fs.readFileSync(new URL('../docs/analytics.js',import.meta.url),'utf8');
function site(blocked=false){
 const requests=[];const controls={};
 const button=choice=>({dataset:{analyticsConsent:choice},addEventListener:(type,fn)=>{controls[choice]=fn;}});
 const yes=button('yes'),no=button('no');const link={dataset:{downloadPlacement:'hero'},addEventListener:(type,fn)=>{controls.download=fn;}};
 const context={window:{machogsAnalyticsConfig:{host:'https://native-analytics-production.up.railway.app',project:'machogs',version:'1.4.3'},addEventListener(){}},
 location:{search:'',hostname:'bnishit.github.io',pathname:'/machogs/'},navigator:{globalPrivacyControl:blocked},
 document:{visibilityState:'visible',addEventListener(){},querySelectorAll(selector){
  if(selector==='[data-analytics-consent]')return [yes,no];
  if(selector==='[data-analytics-consent="yes"]')return [yes];
  if(selector==='a[data-download-placement]')return [link];return [];
 }},localStorage:{getItem:()=>null,setItem(){}},crypto:{randomUUID},URLSearchParams,AbortController,
 fetch:(url,options)=>{requests.push({url,body:JSON.parse(options.body),options});return Promise.resolve({ok:true});},Set};
 vm.runInNewContext(source,context);return {requests,controls,yes};
}
test('website needs fresh consent and sends fixed native events without keys',()=>{
 const {requests,controls}=site();assert.equal(requests.length,0);
 controls.yes();controls.download();assert.equal(requests.length,2);
 assert.equal(requests[0].url,'https://native-analytics-production.up.railway.app/v1/relay/machogs');
 assert.equal(requests[0].body.event,'web.page_view');assert.equal(requests[1].body.event,'web.download_clicked');
 assert.equal(requests[1].body.placement,'hero');assert.equal(requests[0].body.install_id,requests[1].body.install_id);
 assert.deepEqual(Object.keys(requests[0].body).sort(),['consent','event','feature','id','install_id','outcome','version']);
 assert.equal(requests[0].options.credentials,'omit');assert.equal(requests[0].options.referrerPolicy,'no-referrer');
 controls.no();controls.download();assert.equal(requests.length,2);
});
test('browser privacy signal always blocks collection',()=>{
 const {requests,controls,yes}=site(true);controls.yes();controls.download();assert.equal(requests.length,0);assert.equal(yes.disabled,true);
});
