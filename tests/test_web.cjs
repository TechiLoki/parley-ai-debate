// State-rendering checks with a minimal DOM substitute; not browser/layout tests.
const {test}=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
function setup(){
  const nodes=new Map();
  function node(){return {hidden:false,disabled:false,textContent:'',innerHTML:'',value:'',style:{},scrollHeight:100,scrollTop:0,clientHeight:100,addEventListener(){},classList:{add(){},toggle(){},remove(){}},querySelector(){return node();}};}
  const context=vm.createContext({console,Intl,Date,Map,Set,JSON,Number,String,Object,Array,Math,Blob,URL,setTimeout,clearTimeout,
    document:{getElementById(id){if(!nodes.has(id))nodes.set(id,node());return nodes.get(id);},addEventListener(){},body:{classList:{remove(){},toggle(){}}}},
    localStorage:{setItem(){},getItem(){return null;},removeItem(){}},matchMedia(){return {matches:false};}});
  const code=fs.readFileSync(require('node:path').join(__dirname,'../web/app.js'),'utf8');
  vm.runInContext(code.slice(0,code.indexOf('\ninit();')),context);
  return {nodes,run:code=>vm.runInContext(code,context)};
}
const room={id:'room',title:'A discussion',status:'running',turn_count:0,config:{topic:'A question?',instructions:'Be kind.',rounds:1,participants:[{name:'A',personality:'analyst',color:'blue',model:{model:'tiny'}},{name:'B',personality:'skeptic',color:'teal',model:{model:'tiny'}}]}};
test('empty workspace shows onboarding and disables room actions',()=>{
  const {nodes,run}=setup();run('renderRoom()');
  assert.equal(nodes.get('welcome').hidden,false);
  assert.equal(nodes.get('thread').hidden,true);
  assert.equal(nodes.get('export-button').disabled,true);
});
test('active and completed room state drives controls',()=>{
  const {nodes,run}=setup();run(`state.current=${JSON.stringify(room)};renderRoom()`);
  assert.equal(nodes.get('typing').hidden,false);
  assert.equal(nodes.get('run-button').textContent,'Ⅱ Pause');
  run("state.current.status='completed';state.current.turn_count=2;renderRoom()");
  assert.equal(nodes.get('typing').hidden,true);
  assert.equal(nodes.get('run-button').disabled,true);
  assert.equal(nodes.get('progress-detail').textContent,'2 / 2 agent turns');
});
test('model and user content are rendered as text, with retry on failure',()=>{
  const {nodes,run}=setup();run(`state.current=${JSON.stringify({...room,status:'failed',error:'Model unavailable'})};state.messages=[{id:'m',kind:'user',speaker:'You',content:'<img src=x onerror=alert(1)>',created_at:'2026-11-17T12:00:00Z'}];renderRoom()`);
  assert.match(nodes.get('thread').innerHTML,/&lt;img/);
  assert.doesNotMatch(nodes.get('thread').innerHTML,/<img src=x/);
  assert.equal(nodes.get('run-error').textContent,'Model unavailable');
  assert.equal(nodes.get('run-button').textContent,'↻ Retry turn');
});
