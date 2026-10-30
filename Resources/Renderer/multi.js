(() => {
  class MultiSendQueue {
    constructor(api, callbacks={}) {this.api=api;this.callbacks=callbacks;this.running=false;this.current=null;this.cancelled=false;this.total=0;}
    async start(recipients,paths) {
      if(this.running)throw Error('Batch already running');
      const ids=[...new Set(recipients)];
      if(!ids.length||!paths.length)return [];
      this.running=true;this.cancelled=false;this.total=ids.length;const results=[];
      try {
        for(const peerId of ids) {
          if(this.cancelled)break;
          this.callbacks.onStart?.(peerId);
          let resolveEvent,transferId,early=[];
          const event=new Promise(resolve=>{resolveEvent=resolve;});
          const off=this.api.onEvent(e=>{
            if(e.peerId!==peerId||!['send-done','send-failed'].includes(e.type))return;
            if(!transferId){early.push(e);return;}
            if(e.id===transferId)resolveEvent(e);
          });
          let result;
          try {
            transferId=await this.api.send(peerId,paths);
            this.current={peerId,id:transferId};this.callbacks.onCreated?.(peerId,transferId);
            const completed=early.find(e=>e.id===transferId);if(completed)resolveEvent(completed);early=[];
            if(this.cancelled)this.api.cancel(transferId);
            const terminal=await event;
            result={peerId,status:terminal.type==='send-done'?'done':terminal.cancelled?'cancelled':terminal.declined?'declined':'failed',error:terminal.error};
          } catch(error) {result={peerId,status:'failed',error:error.message};}
          finally {off();this.current=null;}
          results.push(result);this.callbacks.onResult?.(result);
        }
        return results;
      } finally {this.running=false;this.callbacks.onFinish?.(results,this.cancelled);}
    }
    cancel() {this.cancelled=true;if(this.current)this.api.cancel(this.current.id);}
  }
  if(typeof module!=='undefined')module.exports={MultiSendQueue};
  if(typeof document==='undefined')return;
  const selected=new Set();let selecting=false,picking=false;
  const labels={ru:{toggle:'Выбрать несколько устройств',select:'Выберите получателей',selected:'Выбрано устройств: ',send:'Отправить',cancel:'Отмена',stop:'Остановить',sending:'Отправка выбранным устройствам',queued:'В очереди',done:'Отправлено',failed:'Ошибка',declined:'Отклонено',cancelled:'Отменено',summary:'Рассылка завершена'},en:{toggle:'Select multiple devices',select:'Choose recipients',selected:'Selected devices: ',send:'Send',cancel:'Cancel',stop:'Stop',sending:'Sending to selected devices',queued:'Queued',done:'Sent',failed:'Failed',declined:'Declined',cancelled:'Cancelled',summary:'Batch finished'}};
  Object.assign(labels.ru,{entry:'Выбрать устройства',note:'Отметьте получателей на радаре',all:'Выбрать все',none:'Снять все',entryNote:'Один набор файлов — нескольким получателям'});
  Object.assign(labels.en,{entry:'Select devices',note:'Mark recipients on the radar',all:'Select all',none:'Clear all',entryNote:'One file selection — multiple recipients'});
  const strings=()=>labels[window.hopI18n?.language==='en'?'en':'ru'];
  const statuses=new Map();
  const panel=document.createElement('div');panel.className='multi-controls';panel.hidden=true;
  const caption=document.createElement('div');caption.className='multi-caption';
  caption.setAttribute('aria-live','polite');
  const note=document.createElement('div');note.className='multi-note';
  const selectAll=document.createElement('button');selectAll.className='multi-all';selectAll.type='button';
  const heading=document.createElement('div');heading.className='multi-heading';heading.append(caption,selectAll);
  const actions=document.createElement('div');actions.className='actions';
  const submit=document.createElement('button');submit.className='btn primary';
  const cancel=document.createElement('button');cancel.className='btn';
  actions.append(cancel,submit);panel.append(heading,note,actions);document.body.append(panel);
  const entry=document.createElement('div');entry.className='multi-entry';
  const entryButton=document.createElement('button');entryButton.type='button';entryButton.className='multi-entry-button';
  const entryIcon=document.createElement('span');entryIcon.innerHTML='<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="5"/><path d="m7 12 3 3 7-7"/></svg>';
  const entryLabel=document.createElement('span');entryButton.append(entryIcon,entryLabel);const entryNote=document.createElement('div');entryNote.className='multi-entry-note';entry.append(entryButton,entryNote);document.getElementById('hint').append(entry);
  function refresh() {
    const t=strings();entryButton.title=t.entry;entryButton.setAttribute('aria-label',t.entry);entryButton.setAttribute('aria-pressed',String(selecting));
    panel.hidden=!selecting;document.body.classList.toggle('multi-selecting',selecting);
    panel.style.bottom=(document.querySelector('.footer').offsetHeight+14)+'px';
    caption.textContent=queue.running?t.sending:t.selected+selected.size;
    note.textContent=t.note;entryLabel.textContent=t.entry;entryNote.textContent=t.entryNote;
    selectAll.textContent=selected.size&&selected.size===state.peers.size?t.none:t.all;selectAll.disabled=queue.running||picking||!state.peers.size;
    submit.textContent=t.send+(selected.size?' ('+selected.size+')':'');submit.disabled=queue.running||picking||!selected.size;
    cancel.textContent=queue.running?t.stop:t.cancel;
    for(const node of document.querySelectorAll('.peer:not(.leave)')) {
      const id=node.dataset.id;node.classList.toggle('multi-selected',selected.has(id));
      node.setAttribute('aria-selected',String(selected.has(id)));
      let status=node.querySelector('.multi-status');
      const value=statuses.get(id);
      if(value){if(!status){status=document.createElement('div');status.className='multi-status';node.append(status);}status.textContent=t[value]||'';}
      else status?.remove();
    }
    layout();
  }
  const queue=new MultiSendQueue(window.hop,{
    onStart(id){statuses.delete(id);setActivity(id,{dir:'out',stage:'waiting',sent:0,total:0});refresh();},
    onCreated(id,transferId){const act=state.activity.get(id);if(act&&!act.result)act.id=transferId;},
    onResult(result){statuses.delete(result.peerId);if(result.status==='cancelled')setActivity(result.peerId,null);else if(!state.activity.get(result.peerId)?.result)settleActivity(result.peerId,result.status==='done'?'done':result.status==='declined'?'declined':'failed','out');refresh();},
    onFinish(results,cancelled){selecting=false;selected.clear();statuses.clear();refresh();const successful=results.filter(r=>r.status==='done').length;toast(`${strings().summary}: ${successful}/${queue.total}${cancelled?' · '+strings().cancelled:''}`);},
  });
  function setSelecting(value) {
    if(queue.running||picking)return;
    if(value&&[...state.activity.values()].some(a=>!a.result)){toast(window.hopI18n.translate('Wait for the current transfer to finish.'));return;}
    selecting=value;selected.clear();statuses.clear();refresh();
  }
  entryButton.addEventListener('click',()=>setSelecting(true));
  selectAll.addEventListener('click',()=>{if(queue.running||picking)return;const allSelected=selected.size===state.peers.size;selected.clear();if(!allSelected)for(const id of state.peers.keys())selected.add(id);refresh();});
  document.addEventListener('click',event=>{
    const node=event.target.closest('.peer');if(!node)return;
    if(queue.running){event.stopImmediatePropagation();event.preventDefault();return;}
    if(!selecting)return;
    event.stopImmediatePropagation();event.preventDefault();const id=node.dataset.id;
    if(!state.peers.has(id))return;
    selected.has(id)?selected.delete(id):selected.add(id);refresh();
  },true);
  async function sendSelection() {
    if(queue.running||picking||!selected.size)return;
    const ids=[...selected];
    picking=true;refresh();let paths;
    try{paths=await window.hop.pick();}catch(error){toast(error.message);return;}finally{picking=false;refresh();}
    if(!paths?.length)return;
    for(const id of ids)statuses.set(id,'queued');
    // Each native backend keeps its existing transfer semantics. Android processes
    // recipients in order, so one selected file set works on both platforms.
    const result=queue.start(ids,paths);refresh();await result;
  }
  submit.addEventListener('click',()=>sendSelection().catch(error=>toast(error.message)));
  cancel.addEventListener('click',()=>{if(queue.running)queue.cancel();else setSelecting(false);});
  window.hop.onEvent(event=>{if(event.type==='peers')queueMicrotask(()=>{
    if(!queue.running&&!picking)for(const id of selected)if(!state.peers.has(id))selected.delete(id);
    refresh();
  });});
  window.addEventListener('hop-language',refresh);
  window.addEventListener('resize',refresh);
  window.hopMulti={get running(){return queue.running;},get selected(){return [...selected];}};
  refresh();
})();
