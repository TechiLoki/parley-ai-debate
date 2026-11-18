'use strict';
const $ = id => document.getElementById(id);
const PERSONALITIES = {analyst:'Analyst',skeptic:'Skeptic',optimist:'Optimist',pragmatist:'Pragmatist',mediator:'Mediator',visionary:'Visionary',custom:'Custom'};
const COLORS = ['violet','teal','amber','rose','blue','lime'];
const state = {conversations:[],scenarios:[],models:[],current:null,messages:[],query:'',polling:false,loading:false,threadKey:''};
let selectionVersion=0;
const esc = value => String(value ?? '').replace(/[&<>"']/g, ch => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));
const initial = name => String(name || '?').trim().slice(0,1).toUpperCase();
const avatar = (name,color='violet') => `<div class="avatar ${COLORS.includes(color)?color:'violet'}">${esc(initial(name))}</div>`;
const statusLabel = status => ({idle:'Ready',queued:'Waiting for next turn',running:'In conversation',paused:'Paused',completed:'Complete',failed:'Needs attention'}[status]||status);
let toastTimer;
function toast(text){$('toast').textContent=text;$('toast').hidden=false;clearTimeout(toastTimer);toastTimer=setTimeout(()=>$('toast').hidden=true,6000);}
async function api(path, data){
  const response = await fetch('/rest/'+path, data===undefined?{}:{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(data)});
  const text = await response.text();
  let result;
  try{result=text?JSON.parse(text):null;}catch{throw new Error('The database API is not ready. Check the running services.');}
  if(!response.ok)throw new Error(result?.message||result?.error||`Request failed (${response.status})`);
  return result;
}
async function rpc(name,data){return api('rpc/'+name,data);}
async function guarded(button,task,errorElement){
  if(button.disabled)return;
  button.disabled=true;
  if(errorElement)errorElement.textContent='';
  try{await task();}catch(error){if(errorElement)errorElement.textContent=error.message;else toast(error.message);}
  finally{button.disabled=false;}
}
function timeLabel(date){return new Intl.DateTimeFormat(undefined,{hour:'2-digit',minute:'2-digit'}).format(new Date(date));}
function renderList(){
  const items=state.conversations.filter(c=>c.title.toLowerCase().includes(state.query.toLowerCase()));
  $('conversation-count').textContent=state.conversations.length;
  $('conversation-list').innerHTML=items.length?items.map(c=>`<button class="conversation-item ${c.id===state.current?.id?'active':''}" data-conversation="${c.id}" ${c.id===state.current?.id?'aria-current="page"':''}><span class="conversation-icon">♧</span><span class="conversation-text"><strong>${esc(c.title)}</strong><small>${esc(statusLabel(c.status))} · ${c.turn_count} agent messages</small></span>${['running','queued'].includes(c.status)?'<span class="mini-dot"></span>':''}</button>`).join(''):'<p class="list-empty muted">No conversations here yet.</p>';
}
function renderStarters(){
  $('starter-cards').innerHTML=state.scenarios.slice(0,3).map((s,i)=>`<button class="starter-card" data-start="${s.id}"><span class="starter-symbol">${['◷','⌘','◇'][i]}</span><strong>${esc(s.title)}</strong><small>${s.participants.length} voices · ${s.rounds} rounds ↗</small></button>`).join('');
}
function renderRoom(){
  const c=state.current;
  $('welcome').hidden=!!c;$('thread').hidden=!c;$('composer-area').hidden=!c;
  for(const id of ['export-button','delete-button'])$(id).disabled=!c;
  $('room-title').textContent=c?.title||'A room for every perspective';
  $('room-status').textContent=c?statusLabel(c.status):'Ready to explore';
  $('room-status').className='status-pill '+(c?.status||'');
  $('typing').hidden=!c||!['running','queued'].includes(c.status);
  if(!c){
    $('participant-list').innerHTML='<p class="muted">Your cast will appear here.</p>';
    $('topic-text').textContent='Choose a starter or create a scenario to begin.';
    $('scenario-rules').textContent='';$('rounds-value').textContent='—';$('messages-value').textContent='0';return;
  }
  const members=c.config.participants,total=members.length*c.config.rounds;
  const next=members[c.turn_count%members.length];
  $('typing-label').textContent=`${next.name} is thinking…`;
  $('participant-list').innerHTML=members.map(p=>`<div class="participant">${avatar(p.name,p.color)}<div><strong>${esc(p.name)}</strong><div class="personality-label">${esc(PERSONALITIES[p.personality]||p.personality)}</div><small>${esc(p.model.model)}</small></div></div>`).join('');
  $('topic-text').textContent=c.config.topic;
  $('scenario-rules').innerHTML=c.config.instructions?`<p class="rules-text">${esc(c.config.instructions)}</p>`:'';
  $('rounds-value').textContent=c.config.rounds;$('messages-value').textContent=state.messages.length;
  $('progress-label').textContent=c.status==='completed'?'Every voice has had its say':`Round ${Math.min(Math.floor(c.turn_count/members.length)+1,c.config.rounds)} of ${c.config.rounds}`;
  $('progress-detail').textContent=`${c.turn_count} / ${total} agent turns`;
  const active=['queued','running'].includes(c.status);
  $('run-button').textContent=active?'Ⅱ Pause':c.status==='completed'?'✓ Conversation complete':c.status==='idle'?'▶ Start conversation':c.status==='failed'?'↻ Retry turn':'▶ Resume';
  $('run-button').disabled=c.status==='completed';
  $('run-error').hidden=!c.error;$('run-error').textContent=c.error||'';
  const key=c.id+':'+state.messages.map(m=>m.id).join(',');
  if(key!==state.threadKey){
    const thread=$('thread');const nearBottom=thread.scrollHeight-thread.scrollTop-thread.clientHeight<100;
    const changedRoom=!state.threadKey.startsWith(c.id+':');
    let count=0;
    const html=state.messages.map(m=>{
      let divider='';
      if(m.kind==='agent'&&count++%members.length===0)divider=`<div class="round-divider">ROUND ${Math.ceil(count/members.length)}</div>`;
      return divider+`<article class="message ${m.kind==='user'?'user':''}">${avatar(m.speaker,m.color)}<div class="message-main"><div class="message-meta"><strong>${esc(m.speaker)}</strong><time datetime="${esc(m.created_at)}">${esc(timeLabel(m.created_at))}</time>${m.model?`<small>${esc(m.model)}</small>`:''}</div><div class="bubble">${esc(m.content)}</div>${m.duration_ms!=null?`<div class="message-foot">${(m.duration_ms/1000).toFixed(1)}s · ${esc(m.model)}</div>`:''}</div></article>`;
    }).join('');
    thread.innerHTML=`<div class="thread-intro"><span class="eyebrow">THE CONVERSATION STARTS WITH A QUESTION</span><h2>${esc(c.title)}</h2><p>${esc(c.config.topic)}</p></div>${html||'<div class="empty-thread">Your cast is ready. Start the conversation, or send an opening thought.</div>'}`;
    state.threadKey=key;
    if(nearBottom||changedRoom)thread.scrollTop=thread.scrollHeight;
  }
}
async function loadCatalog(){
  const [scenarios,models]=await Promise.all([api('scenarios?select=*,participants(*,model_profiles(*))&order=created_at.desc'),api('model_profiles?order=created_at.asc')]);
  state.scenarios=scenarios.map(s=>({...s,participants:s.participants.sort((a,b)=>a.position-b.position)}));state.models=models;
  renderStarters();
}
async function refresh(){
  if(state.polling||state.loading)return;
  state.polling=true;
  const id=state.current?.id;
  const version=selectionVersion;
  try{
    const conversations=await api('conversations?order=updated_at.desc&limit=100');
    state.conversations=conversations;
    if(id&&state.current?.id===id){
      let c=conversations.find(c=>c.id===id);
      if(!c)c=(await api(`conversations?id=eq.${id}`))[0];
      const messages=c?await api(`messages?conversation_id=eq.${id}&order=sequence.asc&limit=1000`):[];
      if(state.current?.id===id&&selectionVersion===version){state.current=c||null;state.messages=messages;}
    }
    renderList();renderRoom();
  }catch(error){$('connection-title').textContent='Connection interrupted';$('connection-dot').classList.add('offline');}
  finally{state.polling=false;}
}
async function selectConversation(id){
  const version=++selectionVersion;
  state.loading=true;
  try{
    const [rows,messages]=await Promise.all([api(`conversations?id=eq.${id}`),api(`messages?conversation_id=eq.${id}&order=sequence.asc&limit=1000`)]);
    if(version!==selectionVersion)return;
    if(!rows.length)throw new Error('Conversation no longer exists.');
    state.current=rows[0];state.messages=messages;state.threadKey='';
    localStorage.setItem('parley-current',id);document.body.classList.remove('menu-open');renderList();renderRoom();
  }finally{if(version===selectionVersion)state.loading=false;}
}
async function createFromScenario(id){
  const result=await rpc('create_conversation',{p_scenario_id:id});
  $('library-dialog').close();await selectConversation(result);await refresh();
}
function openLibrary(){
  $('library-list').innerHTML=state.scenarios.map(s=>`<article class="library-card"><h3>${esc(s.title)}</h3><p>${esc(s.topic)}</p><small>${s.participants.length} voices · ${s.rounds} rounds · ${esc(s.participants.map(p=>p.name).join(', '))}</small><div class="library-actions"><button class="primary compact" data-start="${s.id}">Open a room ↗</button><button class="secondary compact" data-copy="${s.id}">Customize a copy</button></div></article>`).join('')||'<p class="muted">Create a scenario to fill your library.</p>';
  $('library-dialog').showModal();
}
function modelOptions(selected){return state.models.map(m=>`<option value="${m.id}" ${m.id===selected?'selected':''}>${esc(m.name)} · ${esc(m.model)}</option>`).join('');}
function addParticipant(data={}){
  const list=$('participant-editor');
  if(list.children.length>=6)return;
  const index=list.children.length;
  const defaults=[{name:'Maya',personality:'optimist',color:'teal',stance:'Defend adopting the proposal. Challenge objections and give concrete reasons for the change.'},{name:'Theo',personality:'skeptic',color:'amber',stance:'Oppose adopting the proposal as stated. Defend a specific alternative and challenge the promised benefits.'},{name:'Alex',personality:'mediator',color:'violet',stance:'Reject both blanket adoption and doing nothing. Defend a conditional alternative and challenge both sides.'}];
  data={...(defaults[index]||{name:'Voice '+(index+1),personality:'analyst',color:COLORS[index],stance:'Challenge the other proposals from the perspective of those who bear their costs.'}),...data};
  const node=document.createElement('section');node.className='editor-card';
  node.innerHTML=`<div class="editor-card-header">${avatar(data.name,data.color)}<strong>PARTICIPANT</strong><button type="button" class="icon-button remove-participant" aria-label="Remove participant">×</button></div><div class="two-cols"><label>Name<input data-field="name" required maxlength="50" value="${esc(data.name)}"></label><label>Personality<select data-field="personality">${Object.entries(PERSONALITIES).map(([key,label])=>`<option value="${key}" ${key===data.personality?'selected':''}>${label}</option>`).join('')}</select></label></div><div class="two-cols"><label>Model profile<select data-field="model_profile_id" required>${modelOptions(data.model_profile_id)}</select></label><label>Accent color<select data-field="color">${COLORS.map(c=>`<option value="${c}" ${c===data.color?'selected':''}>${c}</option>`).join('')}</select></label></div><label>Position or perspective<input data-field="stance" required maxlength="1000" value="${esc(data.stance||'')}" placeholder="Required: what should this person defend or oppose?"></label><details ${data.custom_prompt?'open':''}><summary>Additional character instructions</summary><textarea data-field="custom_prompt" maxlength="1500" rows="2" placeholder="Values, speaking style, or a custom personality…">${esc(data.custom_prompt||'')}</textarea></details>`;
  list.appendChild(node);updateCastButtons();
}
function updateCastButtons(){const cards=[...$('participant-editor').children];cards.forEach((card,i)=>{card.querySelector('strong').textContent=`PARTICIPANT ${i+1}`;card.querySelector('.remove-participant').disabled=cards.length<=2;});$('add-participant').disabled=cards.length>=6;}
function openScenario(source){
  if(!state.models.length){toast('Wait for the model profiles to load, or check the database connection.');return;}
  $('library-dialog').close();$('scenario-form').reset();$('scenario-error').textContent='';$('participant-editor').replaceChildren();
  if(source){$('scenario-title').value=source.title+' (copy)';$('scenario-topic').value=source.topic;$('scenario-instructions').value=source.instructions;$('scenario-rounds').value=source.rounds;source.participants.forEach(addParticipant);}
  else{addParticipant();addParticipant();}
  $('scenario-dialog').showModal();
}
function scenarioData(){
  return {title:$('scenario-title').value.trim(),topic:$('scenario-topic').value.trim(),instructions:$('scenario-instructions').value.trim(),rounds:Number($('scenario-rounds').value),participants:[...$('participant-editor').children].map(card=>Object.fromEntries([...card.querySelectorAll('[data-field]')].map(field=>[field.dataset.field,field.value.trim()])))};
}
let savingScenario=false;
async function saveScenario(create,button){
  if(savingScenario||!$('scenario-form').reportValidity())return;
  savingScenario=true;
  try{await guarded(button,async()=>{
    const id=await rpc('save_scenario',{p_data:scenarioData()});
    await loadCatalog();$('scenario-dialog').close();
    if(create)await createFromScenario(id);else toast('Scenario saved to your library.');
  },$('scenario-error'));}finally{savingScenario=false;}
}
async function openSettings(){
  $('model-error').textContent='';
  $('model-list').innerHTML=state.models.map(m=>`<div class="model-row">${avatar(m.provider==='ollama'?'○':'↗')}<div><strong>${esc(m.name)}</strong><small>${esc(m.provider)} · ${esc(m.model)} · ${esc(m.temperature)} temperature · ${m.max_tokens} tokens</small></div></div>`).join('');
  if(!$('settings-dialog').open)$('settings-dialog').showModal();
  try{const response=await fetch('/engine/models');const data=await response.json();$('installed-models').textContent=data.models?.join(', ')||'No models available yet. The first download may take a few minutes.';}
  catch{$('installed-models').textContent='Cannot reach the model service.';}
}
async function checkEngine(){
  try{
    const [h,m]=await Promise.all([fetch('/engine/health').then(r=>r.json()),fetch('/engine/models').then(r=>r.json())]);
    const ready=h.worker?.connected&&m.models?.length>0;
    $('connection-dot').classList.toggle('offline',!ready);
    $('connection-title').textContent=ready?'Local engine ready':'Engine warming up';
    $('connection-detail').textContent=!h.worker?.connected?'Waiting for database API':m.models?.length?'CPU · one model at a time':'Downloading your first model';
  }catch{$('connection-dot').classList.add('offline');$('connection-title').textContent='Engine unavailable';$('connection-detail').textContent='Check your Docker services';}
}
$('new-debate').onclick=()=>openScenario();$('welcome-new').onclick=()=>openScenario();
$('templates-button').onclick=openLibrary;$('settings-button').onclick=()=>openSettings();
$('search').oninput=e=>{state.query=e.target.value;renderList();};
$('menu-button').onclick=()=>document.body.classList.toggle('menu-open');
$('details-button').onclick=()=>{if(matchMedia('(max-width:960px)').matches)document.body.classList.toggle('details-open');else document.body.classList.toggle('details-hidden');};
$('add-participant').onclick=()=>addParticipant();
$('participant-editor').onclick=e=>{const remove=e.target.closest('.remove-participant');if(remove){remove.closest('.editor-card').remove();updateCastButtons();}};
$('participant-editor').oninput=e=>{if(e.target.dataset.field==='name')e.target.closest('.editor-card').querySelector('.avatar').textContent=initial(e.target.value);};
$('scenario-form').onsubmit=e=>{e.preventDefault();saveScenario(true,e.submitter);};
$('save-template').onclick=e=>saveScenario(false,e.currentTarget);
$('model-form').onsubmit=e=>{e.preventDefault();guarded(e.submitter,async()=>{
  await rpc('save_model',{p_data:{name:$('model-name').value.trim(),provider:$('model-provider').value,model:$('model-id').value.trim(),temperature:Number($('model-temperature').value),max_tokens:Number($('model-tokens').value)}});
  $('model-form').reset();await loadCatalog();await openSettings();toast('Model profile added. Choose it when creating a scenario.');
},$('model-error'));};
$('run-button').onclick=e=>guarded(e.currentTarget,async()=>{
  if(!state.current)return;
  const active=['running','queued'].includes(state.current.status);
  await rpc('control_conversation',{p_id:state.current.id,p_action:active?'pause':'start'});await refresh();
});
$('message-form').onsubmit=e=>{e.preventDefault();const content=$('message-input').value.trim();if(!content||!state.current)return;const id=state.current.id;guarded(e.submitter||$('message-form').querySelector('button'),async()=>{
  await rpc('post_message',{p_id:id,p_content:content});$('message-input').value='';$('message-input').style.height='auto';await refresh();
});};
$('message-input').onkeydown=e=>{if(e.key==='Enter'&&!e.shiftKey&&!e.isComposing){e.preventDefault();$('message-form').requestSubmit();}};
$('message-input').oninput=e=>{e.target.style.height='auto';e.target.style.height=Math.min(e.target.scrollHeight,120)+'px';};
$('export-button').onclick=()=>{
  if(!state.current)return;
  const c=state.current;
  const text=`# ${c.title}\n\n${c.config.topic}\n\nStatus: ${c.status}\n\n`+state.messages.map(m=>`## ${m.speaker} (${m.kind})\n\n${m.content}\n`).join('\n');
  const url=URL.createObjectURL(new Blob([text],{type:'text/markdown;charset=utf-8'}));
  const a=document.createElement('a');a.href=url;a.download='parley-'+c.id.slice(0,8)+'.md';a.click();setTimeout(()=>URL.revokeObjectURL(url),1000);
};
$('delete-button').onclick=()=>{if(state.current)$('delete-dialog').showModal();};
$('confirm-delete').onclick=e=>guarded(e.currentTarget,async()=>{
  if(!state.current)return;
  const id=state.current.id;
  await rpc('delete_conversation',{p_id:id});
  if(state.current?.id===id){selectionVersion++;state.current=null;state.messages=[];state.threadKey='';localStorage.removeItem('parley-current');}
  $('delete-dialog').close();renderRoom();await refresh();
});
document.addEventListener('click',e=>{
  const close=e.target.closest('.close-dialog');if(close)close.closest('dialog').close();
  const conversation=e.target.closest('[data-conversation]');if(conversation)guarded(conversation,()=>selectConversation(conversation.dataset.conversation));
  const start=e.target.closest('[data-start]');if(start)guarded(start,()=>createFromScenario(start.dataset.start));
  const copy=e.target.closest('[data-copy]');if(copy)openScenario(state.scenarios.find(s=>s.id===copy.dataset.copy));
});
document.addEventListener('keydown',e=>{if(e.key.toLowerCase()==='n'&&!['INPUT','TEXTAREA','SELECT'].includes(document.activeElement.tagName)&&!document.querySelector('dialog[open]')&&!e.ctrlKey&&!e.metaKey&&!e.altKey){e.preventDefault();openScenario();}});
async function init(){
  renderRoom();
  try{await loadCatalog();await refresh();const remembered=localStorage.getItem('parley-current');if(remembered&&state.conversations.some(c=>c.id===remembered))await selectConversation(remembered);}
  catch(error){toast(error.message);$('conversation-list').innerHTML='<p class="list-empty muted">Services are starting. Reconnecting automatically…</p>';}
  await checkEngine();
}
init();
setInterval(async()=>{if(!state.models.length){try{await loadCatalog();}catch{}}await refresh();},2000);
setInterval(checkEngine,15000);
